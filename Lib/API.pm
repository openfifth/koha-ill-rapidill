package Koha::Illbackends::RapidILL::Lib::API;

# Copyright PTFS Europe 2021
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Request;
use JSON qw( encode_json );
use CGI;
use URI;

use Koha::Logger;
use C4::Context;

=head1 NAME

RapidILL - Client interface to RapidILL API plugin (koha-plugin-rapidill)

=cut

sub new {
    my ($class, $config, $VERSION) = @_;

    my $cgi = new CGI;

    my $interface = C4::Context->interface;
    my $url = $interface eq "intranet" ?
        C4::Context->preference('staffClientBaseURL') :
        C4::Context->preference('OPACBaseURL');

    # We need a URL to continue, otherwise we can't make the API call to
    # the RapidILL API plugin
    if (!$url) {
        Koha::Logger->get->warn("Syspref staffClientBaseURL or OPACBaseURL not set!");
        die;
    }

    my $uri = URI->new($url);

    my $self = {
        version => $VERSION,
        ua      => LWP::UserAgent->new,
        cgi     => new CGI,
        config  => $config,
        logger  => Koha::Logger->get({ category => 'Koha.Illbackends.RapidILL.Lib.API' }),
        baseurl => $uri->scheme . "://localhost:" . $uri->port . "/api/v1/contrib/rapidill"
#        baseurl => $uri->scheme . "://" . $uri->host . ":" . $uri->port . "/api/v1/contrib/rapidill"
    };

    bless $self, $class;
    return $self;
}

=head3 InsertRequest

Make a call to the /insertrequest endpoint to create a new request

=cut

sub InsertRequest {
    my ($self, $metadata, $borrowernumber) = @_;

    my $borrower = Koha::Patrons->find( $borrowernumber );

    my @name = grep { defined } ($borrower->firstname, $borrower->surname);

    # Request including passed metadata and credentials
    my $body = encode_json({
        borrowerId => $borrowernumber,
        metadata => {
            PatronId             => $borrower->borrowernumber,
            PatronName           => join (" ", @name),
            PatronNotes          => "== THIS IS A TEST - PLEASE IGNORE! ==",
            IsHoldingsCheckOnly  => 0,
            DoBlockLocalOnly     => 0,
            %{$metadata}
        }
    });

    $body->{metadata}->{PatronEmail} = $borrower->email if $borrower->email;

    my $request = HTTP::Request->new( 'POST', $self->{baseurl} . "/insertrequest" );

    $request->header( "Content-type" => "application/json" );
    $request->content( $body );

    return $self->{ua}->request( $request );
}

=head3 UpdateRequest

Make a call to the updaterequest API endpoint

=cut

sub UpdateRequest {
    my ($self, $request_id, $action, $metadata) = @_;

    $metadata //= {};

    my $body = encode_json({
        requestId    => $request_id,
        updateAction => $action,
        metadata     => $metadata
    });

    my $request = HTTP::Request->new( 'POST', $self->{baseurl} . "/updaterequest" );

    $request->header( "Content-type" => "application/json" );
    $request->content( $body );

    return $self->{ua}->request( $request );
}

1;