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
use JSON         qw( decode_json );
use MIME::Base64 qw( decode_base64 );
use URI::Escape  qw ( uri_unescape );
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
            ClientAppName => "Koha RapidILL client",
            %{$credentials},
            %{$metadata}
        }
    };

    my $client = build_client('InsertRequest');

    my $response = $client->($req);

    return $c->render(
        status  => 200,
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
            RapidRequestId => $body->{requestId},
            UpdateAction   => $body->{updateAction},
            %{$credentials},
            %{$metadata}
        }
    };

    my $client = build_client('UpdateRequest');

    my $response = $client->($req);

    return $c->render(
        status  => 200,
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
            RequestId => $body->{requestId},
            %{$credentials}
        }
    };

    my $client = build_client('RetrieveHistory');

    my $response = $client->($req);

    return $c->render(
        status  => 200,
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
            RequestId => $body->{requestId},
            %{$credentials}
        }
    };

    my $client = build_client('RetrieveRequestInfo');

    my $response = $client->($req);

    return $c->render(
        status  => 200,
        openapi => {
            result => $response->{parameters}->{RetrieveRequestInfoResult},
            errors => []
        }
    );
}

sub Backend_Availability {
    my $c = shift->openapi->valid_input or return;

    my $credentials = _get_credentials();

    my $metadata = $c->validation->param('metadata') || '';
    $metadata = decode_json( decode_base64( uri_unescape($metadata) ) );

    my $rapid_metadata;
    foreach my $key (keys %$metadata) {
        if ( $key eq 'type' ) {
            $rapid_metadata->{'RapidRequestType'} = Koha::Plugin::Com::PTFSEurope::RapidILL->find_rapid_value(
                'RapidRequestType',
                $metadata->{type}
            );
            next;
        }
        my $rapid_key = Koha::Plugin::Com::PTFSEurope::RapidILL->find_rapid_property($key, 1);
        if($rapid_key){
            $rapid_metadata->{$rapid_key} = $metadata->{$key} if $rapid_key;
        }
    }

    $rapid_metadata = Koha::Plugin::Com::PTFSEurope::RapidILL->prepare_rapid_fields( $rapid_metadata, undef, 1 );
    $rapid_metadata->{'IsHoldingsCheckOnly'} = JSON::PP::true;
    $rapid_metadata->{'DoBlockLocalOnly'}    = JSON::PP::false;

    if ( $metadata->{published_date} =~ /^(\d{4})-(\d{1,2})(?:-(\d{1,2}))?$/ ) {
        $rapid_metadata->{JournalMonth} = $2;
    } else {
        return $c->render(
            status  => 404,
            openapi => {
                error => 'Missing month in publication date: ' . $metadata->{published_date},
            }
        );
    }

    # Base request including passed metadata and credentials
    my $req = {
        input => {
            ClientAppName => "Koha RapidILL client",
            %{$credentials},
            %{$rapid_metadata}
        }
    };

    my $client = build_client('InsertRequest');

    my $response = $client->($req);
    my $result   = $response->{parameters}->{InsertRequestResult};

    if ($result->{'LocalHoldings'} && $result->{'LocalHoldings'}->{'LocalHoldingItem'} && length $result->{'LocalHoldings'}->{'LocalHoldingItem'} > 0 ) {
        return $c->render(
            status  => 200,
            openapi => {
                success => "Item is available locally",
            }
        );
    } else {
        $req->{input}->{'PatronNotes'} = 'HOLDING_CHECK_DO_REMOTE_SEARCH';

        my $second_client = build_client('InsertRequest');
        my $second_response = $second_client->($req);
        $result = $second_response->{parameters}->{InsertRequestResult};

        if ( $result->{'FoundMatch'} == 1 && $result->{'NumberOfAvailableHoldings'} > 0 ) {
            return $c->render(
                status  => 200,
                openapi => {
                    success => "Item is available for request",
                }
            );
        } else {
            return $c->render(
                status  => 404,
                openapi => {
                    error => $result->{'VerificationNote'},
                }
            );
        }
    }
}

sub _get_credentials {

    my $plugin = Koha::Plugin::Com::PTFSEurope::RapidILL->new();
    my $config = decode_json( $plugin->retrieve_data("rapid_config") || {} );

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
    my $wsdl      = XML::Compile::WSDL11->new($wsdl_file);

    my $client = $wsdl->compileClient(
        operation => $operation,
        port      => "ApiServiceSoap12"
    );

    return $client;
}

1;
