package MediaWords::ActionRole::Logged;

#
# Action role that logs requests
#

use strict;
use warnings;

use Modern::Perl "2015";
use MediaWords::CommonLibs;

use Moose::Role;
with 'MediaWords::ActionRole::AbstractAuthenticatedActionRole';
use namespace::autoclean;

use HTTP::Status qw(:constants);
use Readonly;

Readonly my $NUMBER_OF_REQUESTED_ITEMS_KEY => 'MediaWords::ActionRole::Logged::requested_items_count';

around execute => sub {

    my $orig = shift;
    my $self = shift;
    my ( $controller, $c ) = @_;

    my $result = $self->$orig( @_ );

    eval {

        my ( $user_email, $user_roles ) = $self->_user_email_and_roles( $c );
        unless ( $user_email and $user_roles )
        {
            $c->response->status( HTTP_FORBIDDEN );
            die 'Invalid API key or authentication cookie. Access denied.';
        }

        my $requested_items_count = $c->stash->{ $NUMBER_OF_REQUESTED_ITEMS_KEY } // 1;

        # Log the request
        my $db = $c->dbis;
        $db->query( 'SELECT upsert_auth_user_request_daily_counts(?, ?)', $user_email, $requested_items_count );
    };

    if ( $@ )
    {
        my $message = $@;

        $c->error( $message );
        $c->detach();
        return undef;
    }

    return $result;
};

# Static helper that sets the number of requested items (e.g. stories) in the Catalyst's stash to be later used by after{}
sub set_requested_items_count($$)
{
    my ( $c, $requested_items_count ) = @_;

    # Will use it later in after{}
    $c->stash->{ $NUMBER_OF_REQUESTED_ITEMS_KEY } = $requested_items_count;
}

1;
