package Koha::Plugin::Com::PTFSEurope::RapidILL::Api;

use Modern::Perl;
use strict;
use warnings;

use File::Basename qw( dirname );
use XML::Compile;
use XML::Compile::WSDL11;
use XML::Compile::SOAP12;
use XML::Compile::SOAP11;
use XML::Compile::Transport::SOAPHTTP;
use JSON qw( decode_json );

use Koha::Logger;
use Koha::Patrons;
use Mojo::Base 'Mojolicious::Controller';
use Koha::Plugin::Com::PTFSEurope::RapidILL;

sub InsertRequest {

    # Validate what we've received
    my $c = shift->openapi->valid_input or return;

    my $credentials = _get_credentials();

    my $body = $c->validation->param('body');

    my $metadata = $body->{metadata} || {};

    # Base request including passed metadata and credentials
    my $req = {
        input => {
            ClientAppName        => "Koha RapidILL client",
            %{$credentials},
            %{$metadata}
        }
    };

    my $client = build_client('InsertRequest');

    my $response = $client->($req);

    return $c->render(
        status => 200,
        openapi => {
            result => $response->{parameters}->{InsertRequestResult},
            errors => []
        }
    );
}

sub UpdateRequest {

    # Validate what we've received
    my $c = shift->openapi->valid_input or return;

    my $credentials = _get_credentials();

    my $body = $c->validation->param('body');

    my $metadata = $body->{metadata} //= {};

    # Base request including passed metadata and credentials
    my $req = {
        input => {
            RapidRequestId       => $body->{requestId},
            UpdateAction         => $body->{updateAction},
            %{$credentials},
            %{$metadata}
        }
    };

    my $client = build_client('UpdateRequest');

    my $response = $client->($req);

    return $c->render(
        status => 200,
        openapi => {
            result => $response->{parameters}->{UpdateRequestResult},
            errors => []
        }
    );
}

sub RetrieveHistory {

    # Validate what we've received
    my $c = shift->openapi->valid_input or return;

    my $credentials = _get_credentials();

    my $body = $c->validation->param('body');

    # Base request including passed metadata and credentials
    my $req = {
        input => {
            RequestId       => $body->{requestId},
            %{$credentials}
        }
    };

    my $client = build_client('RetrieveHistory');

    my $response = $client->($req);

    return $c->render(
        status => 200,
        openapi => {
            result => $response->{parameters}->{RetrieveHistoryResult},
            errors => []
        }
    );
}

sub RetrieveRequestInfo {

    # Validate what we've received
    my $c = shift->openapi->valid_input or return;

    my $credentials = _get_credentials();

    my $body = $c->validation->param('body');

    # Base request including passed metadata and credentials
    my $req = {
        input => {
            RequestId       => $body->{requestId},
            %{$credentials}
        }
    };

    my $client = build_client('RetrieveRequestInfo');

    my $response = $client->($req);

    return $c->render(
        status => 200,
        openapi => {
            result => $response->{parameters}->{RetrieveRequestInfoResult},
            errors => []
        }
    );
}

sub _get_credentials {

    my $plugin = Koha::Plugin::Com::PTFSEurope::RapidILL->new();
    my $config = decode_json($plugin->retrieve_data("rapid_config") || {});

    return {
        UserName             => $config->{username},
        Password             => $config->{password},
        RequestingRapidCode  => $config->{requesting_rapid_code},
        RequestingBranchName => $config->{requesting_branch_name}
    };
}

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