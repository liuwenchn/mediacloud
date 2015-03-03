#!/usr/bin/env perl

#
# Generate supervisord.conf by applying data in mediawords.yml to supervisord.conf.tt2
#

use strict;
use warnings;

BEGIN
{
    use FindBin;
    use lib "$FindBin::Bin/../lib";
}

use Modern::Perl "2013";

use Data::Dumper;

use MediaWords::Util::Config;
use MediaWords::Util::Paths;

use Template;
use File::Slurp;

sub main
{
    my $config       = MediaWords::Util::Config::get_config;
    my $mc_root_path = MediaWords::Util::Paths::mc_root_path;

    my $template_file = "$mc_root_path/supervisor/supervisord.conf.tt2";
    my $output_file   = "$mc_root_path/supervisor/supervisord.conf";

    # template toolkit converts unquoted true and false values to '1' and '0', which
    # confuses the template processing
    $config->{ supervisor }->{ programs } ||= {};
    my $boolean_fields = [ 'autostart', 'autorestart', 'killasgroup', 'stopasgroup' ];

    for my $b ( @{ $boolean_fields } )
    {
        for my $program ( values( %{ $config->{ supervisor }->{ programs } } ) )
        {
            next unless ( defined( $program->{ $b } ) );
            if ( !$program->{ $b } || ( lc( $program->{ $b } ) eq 'false' ) )
            {
                $program->{ $b . '_b' } = 'false';
            }
            elsif ( $program->{ $b } )
            {
                $program->{ $b . '_b' } = 'true';
            }
            else
            {
                $program->{ $b . '_b' } = $program->{ $b };
            }
        }
    }

    my $template = Template->new( ABSOLUTE => 1 );
    my $generated_config = '';
    $template->process( $template_file, $config, \$generated_config )
      or die "Unable to process template: " . $template->error();

    unless ( $generated_config )
    {
        die "Generated configuration is undef or empty.";
    }

    my $output_string = <<EOF;
;
; Media Cloud configuration file for Supervisor (http://supervisord.org/)
;
; DO NOT EDIT THIS FILE. THIS FILE IS RECREATED DURING EACH CALL TO supervisord.sh BY APPLYING
; mediawords.yml TO supervisor.cont.tt2. TO EDIT THE INDIVIDUAL process PROPERTIES, SEE
; mediawords.yml.
;
; To add your own services to Supervisor, create
; "supervisord.user.service_name.conf" and add your additional configuration
; properties there.
;
EOF
    $output_string .= $generated_config;

    write_file( $output_file, \$output_string )
      or die "Unable to write to file '$output_file'";
}

main();
