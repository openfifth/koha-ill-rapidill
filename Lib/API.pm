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

use File::Basename qw( dirname );
use LWP::UserAgent;
use XML::Compile;
use XML::Compile::WSDL11;
use XML::Compile::SOAP12;
use XML::Compile::SOAP11;
use XML::Compile::Transport::SOAPHTTP;

use Koha::Logger;

=head1 NAME

RapidILL - Client interfact to RapidILL API

=cut

sub new {
    my ($class, $config, $VERSION) = @_;

    my $self = {
        version => $VERSION,
        ua      => LWP::UserAgent->new,
        config  => $config,
        logger  => Koha::Logger->get({ category => 'Koha.Illbackends.RapidILL.Lib.API' })
    };

    bless $self, $class;
    return $self;
}

=head3 InsertRequest

Make a call to the InsertRequest API endpoint to create a new request

=cut

sub InsertRequest {
    my ($self, $metadata, $borrower) = @_;

    my $credentials = $self->_get_credentials;

    # Base request including passed metadata and credentials
    my $req = {
        input => {
            PatronId             => $borrower->borrowernumber,
            PatronName           => join (" ", ($borrower->firstname, $borrower->surname)),
            PatronNotes          => "== THIS IS A TEST - PLEASE IGNORE! ==",
            ClientAppName        => "Koha RapidILL client",
            ClientAppVersion     => $self->{version},
            IsHoldingsCheckOnly  => 0,
            DoBlockLocalOnly     => 0,
            %{$credentials},
            %{$metadata}
        }
    };

    $req->{input}->{PatronEmail} = $borrower->email if $borrower->email;

    my $client = build_client('InsertRequest');

    my $response = $client->($req);

    return $response;
}

=head3 UpdateRequest

Make a call to the UpdateRequest API endpoint

=cut

sub UpdateRequest {
    my ($self, $request_id, $action, $metadata) = @_;

    my $credentials = $self->_get_credentials;

    # Base request including credentials
    my $req = {
        input => {
            RapidRequestId => $request_id,
            UpdateAction   => $action,
            %{$credentials},
            %{$metadata}
        }
    };

    my $client = build_client('UpdateRequest');

    my $response = $client->($req);

    return $response;
}

=head3 _get_credentials

Return a hashref containing credentials that is ready to be used in a
request hashref

=cut

sub _get_credentials {
    my ($self) = @_;

    return {
        UserName             => $self->{config}->{username},
        Password             => $self->{config}->{password},
        RequestingRapidCode  => $self->{config}->{requesting_rapid_code},
        RequestingBranchName => $self->{config}->{requesting_branch_name},
    };
}

=head3 build_client

Build and return an XML::Compile::WSDL11 client

=cut

sub build_client {
    my ($operation) = @_;

    open my $wsdl_fh, "<", dirname(__FILE__) . "/rapidill.wsdl" || die "Can't open file $!";
    my $wsdl_file = do { local $/; <$wsdl_fh> };
    my $wsdl = XML::Compile::WSDL11->new($wsdl_file);

    my $client = $wsdl->compileClient(
        operation => $operation,
        port      => "ApiServiceSoap12"
    );

    return $client;
}

1;