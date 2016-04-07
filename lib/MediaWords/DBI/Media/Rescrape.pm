package MediaWords::DBI::Media::Rescrape;

#
# Media (re)scraping utilities
#

use strict;
use warnings;

use Modern::Perl "2015";

use MediaWords::CommonLibs;
use MediaWords::Util::Log;

use MediaWords::DBI::Media;
use MediaWords::DBI::Feeds;
use MediaWords::GearmanFunction::RescrapeMedia;
use Feed::Scrape::MediaWords;

use URI;
use URI::Split;
use Digest::SHA qw(sha256_hex);

# add default feeds for a single medium
sub enqueue_rescrape_media($)
{
    my ( $medium ) = @_;

    return MediaWords::GearmanFunction::RescrapeMedia->enqueue_on_gearman( { media_id => $medium->{ media_id } } );
}

# for each medium in $media, enqueue an RescrapeMedia job for any medium
# that is lacking feeds
sub add_feeds_for_feedless_media
{
    my ( $db, $medium ) = @_;

    my $media_has_active_syndicated_feeds = $db->query(
        <<END,
        SELECT 1
        FROM media
        WHERE media_id = ?
          AND media_has_active_syndicated_feeds(media_id) = 't'
END
        $medium->{ media_id }
    )->hash;

    unless ( $media_has_active_syndicated_feeds )
    {
        say STDERR "Enqueuing media " . $medium->{ media_id } . " for rescraping";
        enqueue_rescrape_media( $medium );
    }
}

# (re-)enqueue RescrapeMedia jobs for all unmoderated media
# ("RescrapeMedia" Gearman function is "unique", so Gearman will skip media
# IDs that are already enqueued)
sub enqueue_rescrape_media_for_unmoderated_media($)
{
    my ( $db ) = @_;

    my $media = $db->query(
        <<EOF
        SELECT *
        FROM media
        WHERE media_has_active_syndicated_feeds(media_id) = 'f'
EOF
    )->hashes;

    map { enqueue_rescrape_media( $_ ) } @{ $media };

    return 1;
}

# Move feed from "feeds_after_rescraping" to "feeds" table
# Note: it doesn't create a transaction itself, so make sure to do that in a caller
sub _move_rescraped_feed_to_feeds_table($$)
{
    my ( $db, $feed_after_rescraping ) = @_;

    unless ( ref $feed_after_rescraping eq ref {} )
    {
        die "Feed is not a hashref.";
    }
    unless ($feed_after_rescraping->{ feeds_after_rescraping_id }
        and $feed_after_rescraping->{ media_id } )
    {
        die "Feed hashref doesn't have required keys.";
    }

    my $feed = {
        media_id    => $feed_after_rescraping->{ media_id },
        name        => $feed_after_rescraping->{ name },
        url         => $feed_after_rescraping->{ url },
        feed_type   => $feed_after_rescraping->{ feed_type },
        feed_status => 'active',
    };

    my $existing_feed = $db->query(
        <<EOF,
        SELECT *
        FROM feeds
        WHERE url = ?
          AND media_id = ?
EOF
        $feed_after_rescraping->{ url },
        $feed_after_rescraping->{ media_id }
    )->hash;
    if ( $existing_feed )
    {
        say STDERR "Feed already exists as feed ID " .
          $existing_feed->{ feeds_id } . " so updating instead of creating a new one; feed: " . dump_terse( $feed );
        $db->update_by_id( 'feeds', $existing_feed->{ feeds_id }, $feed );
    }
    else
    {
        say STDERR "Feed does not exist so creating a new one; feed: " . dump_terse( $feed );
        $db->create( 'feeds', $feed );
    }

    if ( $feed->{ feed_type } eq 'syndicated' )
    {
        # If media is getting rescraped and syndicated feeds were just
        # found, disable the "web_page" feeds that we might have added
        # previously
        my $active_webpage_feeds = $db->query(
            <<EOF,
            SELECT *
            FROM feeds
            WHERE media_id = ?
              AND feed_type = 'web_page'
              AND feed_status = 'active'
EOF
            $feed->{ media_id }
        )->hashes;
        foreach my $active_webpage_feed ( @{ $active_webpage_feeds } )
        {
            say STDERR "Disabling 'web_page' feed ID " .
              $active_webpage_feed->{ feeds_id } . " because syndicated feeds were found";
            MediaWords::DBI::Feeds::disable_feed( $db, $active_webpage_feed->{ feeds_id } );
        }
    }

    $db->query(
        <<EOF,
        DELETE FROM feeds_after_rescraping
        WHERE feeds_after_rescraping_id = ?
EOF
        $feed_after_rescraping->{ feeds_after_rescraping_id }
    );
}

# Search and add new feeds for unmoderated media (media sources that have not
# had default feeds added to them).
#
# Look for feeds that are most likely to be real feeds.  If we find more than
# one but no more than $MAX_DEFAULT_FEEDS of those feeds, use the first such one
# and do not moderate the source.  Else, do a more expansive search and mark
# for moderation.
sub rescrape_media($$)
{
    my ( $db, $media_id ) = @_;

    my $medium = $db->find_by_id( 'media', $media_id );
    unless ( $medium )
    {
        die "Media ID $media_id does not exist.";
    }

    my ( $feed_links, $need_to_moderate ) = Feed::Scrape::get_feed_links_and_need_to_moderate( $db, $medium );

    $db->begin_work;

    $db->query(
        <<EOF,
        DELETE FROM feeds_after_rescraping
        WHERE media_id = ?
EOF
        $media_id
    );

    for my $feed_link ( @{ $feed_links } )
    {
        my $feed = {
            media_id  => $media_id,
            name      => $feed_link->{ name },
            url       => $feed_link->{ url },
            feed_type => $feed_link->{ feed_type } || 'syndicated',
        };

        say STDERR "Creating rescraped feed " . dump_terse( $feed );
        $db->create( 'feeds_after_rescraping', $feed );
    }

    # If we came up with the very same set of feeds after rescraping and the
    # media would need moderation, but we have moderated the very same set of
    # links before (i.e. made the decision about this particular set of feeds),
    # just leave the current set of feeds intact
    my $live_feeds = $db->query(
        <<EOF,
        SELECT media_id,
               name,
               url,
               feed_type
        FROM feeds
        WHERE media_id = ?
          AND feed_type = 'syndicated'
        ORDER BY name, url, feed_type
EOF
        $media_id
    )->hashes;
    my $rescraped_feeds = $db->query(
        <<EOF,
        SELECT media_id,
               name,
               url,
               feed_type
        FROM feeds_after_rescraping
        WHERE media_id = ?
          AND feed_type = 'syndicated'
        ORDER BY name, url, feed_type
EOF
        $media_id
    )->hashes;

    say STDERR "Media ID: " .
      $media_id . "; moderated: " . $medium->{ moderated } . "; need to moderate: " . $need_to_moderate .
      "; rescraped_feeds feeds: " . dump_terse( $rescraped_feeds ) . "; live feeds: " . dump_terse( $live_feeds );

    if ( $need_to_moderate )
    {
        if ( $medium->{ moderated } and dump_terse( $rescraped_feeds ) eq dump_terse( $live_feeds ) )
        {
            say STDERR "Media $media_id would need rescraping but we have " .
              "moderated the very same feeds previously so disabling moderation";

            $db->query(
                <<EOF,
                DELETE FROM feeds_after_rescraping
                WHERE media_id = ?
EOF
                $media_id
            );
        }
        else
        {
            # (Re)set moderated = 'f' so that the media shows up in the moderation page
            say STDERR "Unmoderating media ID $media_id because rescraped feeds require moderation";
            make_media_unmoderated( $db, $media_id );
        }
    }
    else
    {
        # Move all newly scraped feeds to "feeds" table
        my $feeds_after_rescraping = $db->query(
            <<EOF,
            SELECT *
            FROM feeds_after_rescraping
            WHERE media_id = ?
EOF
            $media_id
        )->hashes;
        foreach my $rescraped_feed ( @{ $feeds_after_rescraping } )
        {
            say STDERR "Moving rescraped feed from media ID $media_id to 'feeds' table; rescraped feed: " .
              dump_terse( $rescraped_feed );
            _move_rescraped_feed_to_feeds_table( $db, $rescraped_feed );
        }

        # Set moderated = 't' because maybe this is a new media item that
        # didn't have any feeds previously
        say STDERR "Making media $media_id moderated after moving all rescraped feeds to 'feeds' table";
        make_media_moderated( $db, $media_id );
    }

    update_last_rescraped_time( $db, $media_id );

    $db->commit;
}

# update last_rescraped_time for media
sub update_last_rescraped_time($$)
{
    my ( $db, $media_id ) = @_;

    $db->query(
        <<EOF,
            UPDATE media_rescraping
            SET last_rescrape_time = NOW()
            WHERE media_id = ?
EOF
        $media_id
    );
}

sub make_media_unmoderated($$)
{
    my ( $db, $media_id ) = @_;

    $db->query(
        <<EOF,
            UPDATE media
            SET moderated = 'f'
            WHERE media_id = ?
EOF
        $media_id
    );
}

sub make_media_moderated($$)
{
    my ( $db, $media_id ) = @_;

    $db->query(
        <<EOF,
            UPDATE media
            SET moderated = 't'
            WHERE media_id = ?
EOF
        $media_id
    );
}

# return any media that might be a candidate for merging with the given media source
sub get_potential_merge_media($$)
{
    my ( $db, $medium ) = @_;

    my $host = lc( ( URI::Split::uri_split( $medium->{ url } ) )[ 1 ] );

    my @name_parts = split( /\./, $host );

    my $second_level_domain = $name_parts[ $#name_parts - 1 ];
    if ( ( $second_level_domain eq 'com' ) || ( $second_level_domain eq 'co' ) )
    {
        $second_level_domain = $name_parts[ $#name_parts - 2 ] || 'domainnotfound';
    }

    my $pattern = "%$second_level_domain%";

    return $db->query( "select * from media where ( name like ? or url like ? ) and media_id <> ?",
        $pattern, $pattern, $medium->{ media_id } )->hashes;
}

# merge the tags of medium_a into medium_b
sub merge_media_tags($$$)
{
    my ( $db, $medium_a, $medium_b ) = @_;

    my $tags_ids = $db->query( "select tags_id from media_tags_map mtm where media_id = ?", $medium_a->{ media_id } )->flat;

    for my $tags_id ( @{ $tags_ids } )
    {
        $db->find_or_create( 'media_tags_map', { media_id => $medium_b->{ media_id }, tags_id => $tags_id } );
    }
}

sub add_feed_by_media_name_url_type($$)
{
    my ( $db, $feed ) = @_;

    unless ( $feed->{ media_id } and defined $feed->{ name } and $feed->{ url } and $feed->{ feed_type } )
    {
        die "Feed hashref is not valid.";
    }

    unless ( $feed->{ feed_status } )
    {
        $feed->{ feed_status } = 'active';
    }

    $db->query(
        <<EOF,
        INSERT INTO feeds (media_id, name, url, feed_type, feed_status)
        VALUES (?, ?, ?, ?, ?)
EOF
        $feed->{ media_id }, $feed->{ name }, $feed->{ url }, $feed->{ feed_type }, $feed->{ feed_status }
    );
}

sub get_feed_by_media_name_url_type($$)
{
    my ( $db, $feed ) = @_;

    my $existing_feed = $db->query(
        <<EOF,
        SELECT *
        FROM feeds
        WHERE media_id = ?
          AND name = ?
          AND url = ?
          AND feed_type = ?
EOF
        $feed->{ media_id }, $feed->{ name }, $feed->{ url }, $feed->{ feed_type }
    )->hashes;
    unless ( scalar( @{ $existing_feed } ) )
    {
        die "Feed for media ID $feed->{ media_id } was not found; feed: " . dump_terse( $feed );
    }
    if ( scalar( @{ $existing_feed } ) > 1 )
    {
        die "More than one feed for media ID $feed->{ media_id } was not found; feed: " . dump_terse( $feed );
    }

    $existing_feed = $existing_feed->[ 0 ];

    return $existing_feed;
}

sub delete_rescraped_feed_by_media_name_url_type($$)
{
    my ( $db, $feed ) = @_;

    $db->query(
        <<EOF,
        DELETE FROM feeds_after_rescraping
        WHERE media_id = ?
          AND name = ?
          AND url = ?
          AND feed_type = ?
EOF
        $feed->{ media_id }, $feed->{ name }, $feed->{ url }, $feed->{ feed_type }
    );
}

# Returns an arrayref of hashrefs with unique feeds from both "feeds"
# (existing feeds table) and "feeds_after_rescraping" (rescraped feeds table)
#
# Apart from the default "media_id", "name", "url" and "feed_type" keys, feed
# hashrefs carry the following extra keys:
#
# * "hash" -- SHA256 hash uniquely identifying the feed; based on its media_id,
#   name, URL, and feed_type
# * "diff" -- state of the feed, one of the following values:
#     * "unchanged" -- feed that hasn't changed after rescraping
#     * "added" -- new feed found while rescraping
#     * "removed" -- feed is gone after rescraping
#     * "stale" -- feed is stale (didn't come up with any new stories in quite
#       some time)
# * "last_new_story_time" (only for existing feeds) -- timestamp of when last
#   story was fetched from the feed
# * "is_stale" (only for existing feeds) -- whether or not the feed is "stale"
#   (doesn't provide any new stories for some time; dead)
sub existing_and_rescraped_feeds($$)
{
    my ( $db, $media_id ) = @_;

    # Calculate a "diff" between existing feeds in "feeds" table and
    # rescraped feeds in "feeds_after_rescraping" table
    my $existing_feeds = $db->query(
        <<EOF,
        SELECT media_id,
               name,
               url,
               feed_type,
               last_new_story_time,
               feed_is_stale(feeds.feeds_id) AS is_stale
        FROM feeds
        WHERE media_id = ?
        ORDER BY media_id, name, url, feed_type
EOF
        $media_id
    )->hashes;

    my $rescraped_feeds = $db->query(
        <<EOF,
        SELECT media_id,
               name,
               url,
               feed_type
        FROM feeds_after_rescraping
        WHERE media_id = ?
        ORDER BY media_id, name, url, feed_type
EOF
        $media_id
    )->hashes;

    # Returns unique hash string that can be used to identify a feed
    sub _feed_hash($)
    {
        my $feed = shift;

        unless ( $feed->{ media_id } and defined $feed->{ name } and $feed->{ url } and $feed->{ feed_type } )
        {
            die "Feed hashref is not valid.";
        }

        my $feed_hash_data =
          sprintf( "%s\n%s\n%s\n%s", $feed->{ media_id }, $feed->{ name }, $feed->{ url }, $feed->{ feed_type } );
        my $feed_sha256 = sha256_hex( $feed_hash_data );

        return $feed_sha256;
    }

    sub _feed_uniq(@)
    {
        my %h;
        map {
            if ( $h{ _feed_hash( $_ ) }++ == 0 )
            {
                $_;
            }
            else
            {
                ();
            }
        } @_;
    }

    my @existing_and_rescraped_feeds = _feed_uniq(

        # Existing feeds is passed first, so we'll have extra
        # "last_new_story_time" and "is_stale" columns included into the output
        @{ $existing_feeds },

        @{ $rescraped_feeds }
    );

    # say STDERR "Existing and rescraped feeds: " . dump_terse( \@existing_and_rescraped_feeds );
    foreach my $feed ( @existing_and_rescraped_feeds )
    {
        my $feed_hash = _feed_hash( $feed );

        my $feed_is_among_existing_feeds = 0;
        foreach my $existing_feed ( @{ $existing_feeds } )
        {
            my $existing_feed_hash = _feed_hash( $existing_feed );
            if ( $feed_hash eq $existing_feed_hash )
            {
                $feed_is_among_existing_feeds = 1;
            }
        }

        my $feed_is_among_rescraped_feeds = 0;
        foreach my $rescraped_feed ( @{ $rescraped_feeds } )
        {
            my $rescraped_feed_hash = _feed_hash( $rescraped_feed );
            if ( $feed_hash eq $rescraped_feed_hash )
            {
                $feed_is_among_rescraped_feeds = 1;
            }
        }

        my $feed_diff = '';
        if ( $feed_is_among_existing_feeds and $feed->{ is_stale } )
        {
            $feed_diff = 'stale';
        }
        else
        {
            if ( $feed_is_among_existing_feeds and $feed_is_among_rescraped_feeds )
            {
                $feed_diff = 'unchanged';
            }
            else
            {
                if ( $feed_is_among_existing_feeds and ( !$feed_is_among_rescraped_feeds ) )
                {
                    $feed_diff = 'removed';
                }
                elsif ( ( !$feed_is_among_existing_feeds ) and $feed_is_among_rescraped_feeds )
                {
                    $feed_diff = 'added';
                }
                else
                {
                    die "Feed is not among existing feeds neither rescraped feeds; probably hashing didn't work.";
                }
            }
        }

        $feed->{ hash } = $feed_hash;
        $feed->{ diff } = $feed_diff;
    }

    return \@existing_and_rescraped_feeds;
}

1;