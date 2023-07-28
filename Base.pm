package Koha::Illbackends::RapidILL::Base;

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

use Modern::Perl;
use strict;
use warnings;

use JSON qw( to_json from_json );
use File::Basename qw( dirname );
use C4::Installer;

use Koha::Illbackends::RapidILL::Lib::API;
use Koha::Libraries;
use Koha::Patrons;

our $VERSION = "1.0.0";

sub new {
    my ($class, $params) = @_;

    my $api = Koha::Illbackends::RapidILL::Lib::API->new($VERSION);

    my $self = {
        _api    => $api
    };

    $self->{_logger} = $params->{logger} if ( $params->{logger} ); 
    $self->{templates} = { 
        'RAPIDILL_REQUEST_FAILED'    => dirname(__FILE__) . '/intra-includes/log/rapidill_request_failed.tt',
        'RAPIDILL_REQUEST_SUCCEEDED' => dirname(__FILE__) . '/intra-includes/log/rapidill_request_succeeded.tt'
    };

    bless($self, $class);

    return $self;
}

=head3 create

Handle the "create" flow

=cut

sub create {
    my ($self, $params) = @_;

    my $other = $params->{other};
    my $stage = $other->{stage};

    my $response = {
        cwd            => dirname(__FILE__),
        backend        => $self->name,
        method         => "create",
        stage          => $stage,
        branchcode     => $other->{branchcode},
        cardnumber     => $other->{cardnumber},
        status         => "",
        message        => "",
        error          => 0,
        field_map      => $self->fieldmap_sorted,
        field_map_json => to_json($self->fieldmap())
    };

    # Check for borrowernumber, but only if we're not receiving an OpenURL
    if (
        !$other->{openurl} &&
        (!$other->{borrowernumber} && defined( $other->{cardnumber} ))
    ) {
        $response->{cardnumber} = $other->{cardnumber};

        # 'cardnumber' here could also be a surname (or in the case of
        # search it will be a borrowernumber).
        my ( $brw_count, $brw ) =
          _validate_borrower( $other->{'cardnumber'}, $stage );

        if ( $brw_count == 0 ) {
            $response->{status} = "invalid_borrower";
            $response->{value}  = $params;
            $response->{stage} = "init";
            $response->{error}  = 1;
            return $response;
        }
        elsif ( $brw_count > 1 ) {
            # We must select a specific borrower out of our options.
            $params->{brw}     = $brw;
            $response->{value} = $params;
            $response->{stage} = "borrowers";
            $response->{error} = 0;
            return $response;
        }
        else {
            $other->{borrowernumber} = $brw->borrowernumber;
        }

        $self->{borrower} = $brw;
    }

    # Initiate process
    if ( !$stage || $stage eq 'init' ) {

        # First thing we want to do, is check if we're receiving
        # an OpenURL and transform it into something we can
        # understand
        if ($other->{openurl}) {
            # We only want to transform once
            delete $other->{openurl};
            $params = _openurl_to_ill($params);
        }

        # Pass the map of form fields in forms that can be used by TT
        # and JS
        $response->{field_map} = $self->fieldmap_sorted;
        $response->{field_map_json} = to_json($self->fieldmap());
        # We just need to request the snippet that builds the Creation
        # interface.
        $response->{stage} = 'init';
        $response->{value} = $params;
        return $response;
    }
    # Validate form and perform search if valid
    elsif ( $stage eq 'validate' || $stage eq 'form' ) {

        if ( _fail( $other->{'branchcode'} ) ) {
            # Pass the map of form fields in forms that can be used by TT
            # and JS
            $response->{field_map} = $self->fieldmap_sorted;
            $response->{field_map_json} = to_json($self->fieldmap());
            $response->{status} = "missing_branch";
            $response->{error}  = 1;
            $response->{stage}  = 'init';
            $response->{value}  = $params;
            return $response;
        }
        elsif ( !Koha::Libraries->find( $other->{'branchcode'} ) ) {
            # Pass the map of form fields in forms that can be used by TT
            # and JS
            $response->{field_map} = $self->fieldmap_sorted;
            $response->{field_map_json} = to_json($self->fieldmap());
            $response->{status} = "invalid_branch";
            $response->{error}  = 1;
            $response->{stage}  = 'init';
            $response->{value}  = $params;
            return $response;
        }
        elsif ( !$other->{opac} && !$self->_validate_metadata($other) ) {
            # We don't have sufficient metadata for request creation,
            # create a local submission for later attention
            $self->create_submission($params);

            $response->{stage} = "commit";
            $response->{next} = "illview";
            return $response;
        }
        else {
            # We can submit a request directly to RapidILL
            my $result = $self->submit_and_request($params);

            if ($result->{success}) {
                $response->{stage}  = "commit";
                $response->{next} = "illview";
                $response->{params} = $params;
            } else {
                $response->{error}  = 1;
                $response->{stage}  = 'commit';
                $response->{next} = "illview";
                $response->{params} = $params;
                $response->{message} = $result->{message};
            }

            return $response;
        }
    }
}

=head3 cancel

   Attempt to cancel a request with Rapid 

=cut

sub cancel {
    my ($self, $params) = @_;

    # Update the submission's status
    $params->{request}->status("CANCREQ")->store;

    # Find the submission's Rapid ID
    my $rapid_request_id = $params->{request}->illrequestattributes->find({
        illrequest_id => $params->{request}->illrequest_id,
        type          => "RapidRequestId"
    });

    if (!$rapid_request_id) {
        # No Rapid request, we don't need to do anything else
        return { success => 1 };
    }

    # This submission was submitted to Rapid, so we can try to cancel it there
    my $response = $self->{_api}->UpdateRequest(
        $rapid_request_id->value,
        "Cancel"
    );

    # If the cancellation was successful, note that in Staff notes
    my $body = from_json($response->decoded_content);
    if ($response->is_success && $body->{result}->{IsSuccessful}) {
        $params->{request}->notesstaff(
            join("\n\n", ($params->{request}->notesstaff || "", "Cancelled with RapidILL"))
        )->store;
        return {
            cwd    => dirname(__FILE__),
            method => "cancel",
            stage  => "commit",
            next   => "illview"
        };
    }
    # The call to RapidILL failed for some reason. Add the message we got back from the API
    # to the submission's Staff Notes
    $params->{request}->notesstaff(
        join("\n\n", ($params->{request}->notesstaff || "", "RapidILL request cancellation failed:\n" . $body->{result}->{VerificationNote} || ""))
    )->store;
    # Return the message
    return {
        cwd     => dirname(__FILE__),
        method  => "cancel",
        stage   => "init",
        error   => 1,
        message => $body->{result}->{VerificationNote}
    };
}

=head3 illview

   View and manage an ILL request

=cut

sub illview {
    my ($self, $params) = @_;

    return {
        field_map_json => to_json(fieldmap()),
        method         => "illview"
    };
}

=head3 edititem

Edit an item's metadata

=cut

sub edititem {
    my ($self, $params) = @_;

    # Don't allow editing of requested submissions
    return {
        cwd    => dirname(__FILE__),
        method => 'illlist'
    } if $params->{request}->status ne 'NEW';

    my $other = $params->{other};
    my $stage = $other->{stage};
    if ( !$stage || $stage eq 'init' ) {
        my $attrs = $params->{request}->illrequestattributes->unblessed;
        foreach my $attr(@{$attrs}) {
            $other->{$attr->{type}} = $attr->{value};
        }
        return {
            cwd     => dirname(__FILE__),
            error   => 0,
            status  => '',
            message => '',
            method  => 'edititem',
            stage   => 'form',
            value   => $params,
            field_map => $self->fieldmap_sorted,
            field_map_json => to_json($self->fieldmap)
        };
    } elsif ( $stage eq 'form' ) {
        # Update submission
        my $submission = $params->{request};
        $submission->updated( DateTime->now );
        $submission->store;

        # We may be receiving a submitted form due to the user having
        # changed request material type, so we just need to go straight
        # back to the form, the type has been changed in the params
        if (defined $other->{change_type}) {
            delete $other->{change_type};
            return {
                cwd     => dirname(__FILE__),
                error   => 0,
                status  => '',
                message => '',
                method  => 'edititem',
                stage   => 'form',
                value   => $params,
                field_map => $self->fieldmap_sorted,
                field_map_json => to_json($self->fieldmap)
            };
        }

        # ...Populate Illrequestattributes
        # generate $request_details
        # We do this with a 'dump all and repopulate approach' inside
        # a transaction, easier than catering for create, update & delete
        my $dbh    = C4::Context->dbh;
        my $schema = Koha::Database->new->schema;
        $schema->txn_do(
            sub{
                # Delete all existing attributes for this request
                $dbh->do( q|
                    DELETE FROM illrequestattributes WHERE illrequest_id=?
                |, undef, $submission->id);
                # Insert all current attributes for this request
                my $type = $other->{RapidRequestType};
                my $fields = $self->fieldmap;

                # First insert our RapidILL fields
                foreach my $field(%{$other}) {
                    my $value = $other->{$field};
                    if (
                        grep( /^$type$/, @{$fields->{$field}->{materials}}) &&
                        $other->{$field} &&
                        length $other->{$field} > 0
                    ) {
                        my @bind = ($submission->id, $field, $value, 0);
                        $dbh->do ( q|
                            INSERT IGNORE INTO illrequestattributes
                            (illrequest_id, type, value, readonly) VALUES
                            (?, ?, ?, ?)
                        |, undef, @bind);
                    }
                }

                # Now insert our core equivalents
                foreach my $field(%{$other}) {
                    my $value = $other->{$field};
                    if (
                        grep( /^$type$/, @{$fields->{$field}->{materials}}) &&
                        $other->{$field} &&
                        $fields->{$field}->{ill} &&
                        length $other->{$field} > 0
                    ) {
                        # The value might need mapping to a core equivalent
                        $value = ($fields->{$field}->{value_map}) ?
                            $fields->{$field}->{value_map}->{$value} :
                            $value;
                        my @bind = ($submission->id, $fields->{$field}->{ill}, $value, 0);
                        $dbh->do ( q|
                            INSERT IGNORE INTO illrequestattributes
                            (illrequest_id, type, value, readonly) VALUES
                            (?, ?, ?, ?)
                        |, undef, @bind);
                    }
                }
            }
        );

        # Create response
        return {
            cwd            => dirname(__FILE__),
            error          => 0,
            status         => '',
            message        => '',
            method         => 'create',
            stage          => 'commit',
            next           => 'illview',
            value          => $params,
            field_map      => $self->fieldmap_sorted,
            field_map_json => to_json($self->fieldmap)
        };
    }
}

=head3 migrate

Migrate a request into or out of this backend

=cut

sub migrate {
    my ( $self, $params ) = @_;
    my $other = $params->{other};

    my $stage = $other->{stage};
    my $step  = $other->{step};

    my $fields = $self->fieldmap;

    # We may be receiving a submitted form due to the user having
    # changed request material type, so we just need to go straight
    # back to the form, the type has been changed in the params
    if (defined $other->{change_type}) {
        delete $other->{change_type};
        return {
            cwd     => dirname(__FILE__),
            error   => 0,
            status  => '',
            message => '',
            method  => 'create',
            stage   => 'form',
            value   => $params,
            field_map => $self->fieldmap_sorted,
            field_map_json => to_json($self->fieldmap)
        };
    }

    # Recieve a new request from another backend and suppliment it with
    # anything we require specifically for this backend.
    if ( !$stage || $stage eq 'immigrate' ) {
        my $original_request =
          Koha::Illrequests->find( $other->{illrequest_id} );
        my $new_request = $params->{request};
        $new_request->borrowernumber( $original_request->borrowernumber );
        $new_request->branchcode( $original_request->branchcode );
        $new_request->status('NEW');
        $new_request->backend( $self->name );
        $new_request->placed( DateTime->now );
        $new_request->updated( DateTime->now );
        $new_request->store;

        # Map from Koha's core fields to our metadata fields
        my $original_id = $original_request->illrequest_id;
        my @original_attributes = $original_request->illrequestattributes->search(
            { illrequest_id => $original_id }
        )->as_list;
        my @attributes = keys %{$fields};

        # Look for an equivalent Rapid attribute 
        # for every bit of metadata we receive and, if it exists, map it to the
        # new property
        my $new_attributes = {};
        foreach my $old(@original_attributes) {
            my $rapid = $self->find_rapid_property($old->type);
            if ($rapid) {
                # The value may also need mapping
                my $rapid_value = $self->find_rapid_value($rapid, $old->value);                
                my $value = $rapid_value ? $rapid_value : $old->value;
                $new_attributes->{$rapid} = $value;
            }
        }
        $new_attributes->{migrated_from} = $original_request->illrequest_id;
        while ( my ( $type, $value ) = each %{$new_attributes} ) {
            Koha::Illrequestattribute->new(
                {
                    illrequest_id => $new_request->illrequest_id,
                    # Check required for compatibility with installations before bug 33970
                    column_exists( 'illrequestattributes', 'backend' ) ? (backend =>"RapidILL") : (),
                    type          => $type,
                    value         => $value,
                    readonly      => 0
                }
            )->store;
        }

        return {
            error   => 0,
            status  => '',
            message => '',
            method  => 'migrate',
            stage   => 'commit',
            next    => 'emigrate',
            value   => $params,
            field_map => $self->fieldmap_sorted,
            field_map_json => to_json($self->fieldmap)
        };
    
    } elsif ($stage eq 'emigrate') {
        # We need to cancel any outstanding request with Rapid and then
        # update our local submission
        # Get the request we've migrated from
        my $new_request = $params->{request};
        my $from_id = $new_request->illrequestattributes->find(
            { type => 'migrated_from' } )->value;
        my $request = Koha::Illrequests->find($from_id);

        my $return = {
            error   => 0,
            status  => '',
            message => '',
            method  => 'migrate',
            stage   => 'commit',
            next    => 'illview',
            value   => $params,
            field_map => $self->fieldmap_sorted,
            field_map_json => to_json($self->fieldmap)
        };

        # Cancel a Rapid request if necessary
        my $cancellation = $self->cancel({ request => $request });

        # If there was a problem cancelling with Rapid, we need to pass
        # that on
        if ($cancellation->{error}) {
            $return->{error} = $cancellation->{error};
            $return->{message} = $cancellation->{message};
        }

        return $return;
    }
}

=head3 _validate_metadata

Test if we have sufficient metadata to create a request for
this material type

=cut

sub _validate_metadata {
    my ($self, $metadata) = @_;
    my $fields = $self->fieldmap();
    
    my $type = $metadata->{RapidRequestType};
    my $groups = $self->_build_validation_groups($type);

    foreach my $group(keys %{$groups}) {
        my $group_fields = $groups->{$group};
        if (!_is_group_valid($metadata, $group_fields)) {
            return 0;
        }
    }

    return 1;
}

=head3 _build_validation_groups

Build a data structure from the fieldmap which will enable us
to more easily validate group population

=cut

sub _build_validation_groups {
    my ($self, $type) = @_;
    my $groups = {};
    my $fields = $self->fieldmap();
    foreach my $field(keys %{$fields}) {
        if ($fields->{$field}->{required}) {
            my $req = $fields->{$field}->{required};
            foreach my $material(keys %{$req}) {
                if ($material eq $type) {
                    if (!exists $groups->{$req->{$material}->{group}}) {
                        $groups->{$req->{$material}->{group}} = [ $field ];
                    } else {
                        push (@{$groups->{$req->{$material}->{group}}}, $field);
                    }
                }
            }
        }

    }
    return $groups;
}

=head3 _is_group_valid

Is a metadata group valid? i.e. For a group of fields has
at least one of them been populated?

=cut

sub _is_group_valid {
    my ($metadata, $fields) = @_;

    my $valid = 0;
    foreach my $field(@{$fields}) {
        if  (length $metadata->{$field}) {
            $valid++;
        }
    }

    return $valid;
}

=head3 create_submission

Create a local submission, for later RapidILL request creation

=cut

sub create_submission {
    my ($self, $params) = @_;

    my $patron = Koha::Patrons->find( $params->{other}->{borrowernumber} );

    my $request = $params->{request};
    $request->borrowernumber($patron->borrowernumber);
    $request->branchcode($params->{other}->{branchcode});
    $request->status('NEW');
    $request->backend($self->name);
    $request->placed(DateTime->now);
    $request->updated(DateTime->now);

    $request->store;

    # Store the request attributes
    $self->create_illrequestattributes($request, $params->{other});
    # Now store the core equivalents
    $self->create_illrequestattributes($request, $params->{other}, 1);

    return $request;
}

=head3

Store metadata for a given request for our Rapid fields

=cut

sub create_illrequestattributes {
    my ($self, $request, $metadata, $core) = @_;

    # Get the canonical list of metadata fields
    my $fields = $self->fieldmap;

    my $type = $metadata->{RapidRequestType};

    # Get any existing illrequestattributes for this request,
    # so we can avoid trying to create duplicates
    my $existing_attrs = $request->illrequestattributes->unblessed;
    my $existing_hash = {};
    foreach my $a(@{$existing_attrs}) {
        $existing_hash->{lc $a->{type}} = $a->{value};
    }
    # Iterate our list of fields
    foreach my $field (keys %{$fields}) {
        # If this field is used in the selected material type
        if (
            grep( /^$type$/, @{$fields->{$field}->{materials}}) &&
            # If we're working with core metadata, check if this field
            # has a core equivalent
            (($core && $fields->{$field}->{ill}) || !$core) &&
            $metadata->{$field} &&
            length $metadata->{$field} > 0
        ) {
            my $att_type = $core ? $fields->{$field}->{ill} : $field;
            # We might need to map the attribute value to our core equivalent
            my $att_value = ($core && $fields->{$field}->{value_map}) ?
                $fields->{$field}->{value_map}->{$metadata->{$field}} :
                $metadata->{$field};

            # If it doesn't already exist for this request
            if (!exists $existing_hash->{lc $att_type}) {
                my $data = {
                    illrequest_id => $request->illrequest_id,
                    # Check required for compatibility with installations before bug 33970
                    column_exists( 'illrequestattributes', 'backend' ) ? (backend =>"RapidILL") : (),
                    type          => $att_type,
                    value         => $att_value,
                    readonly      => 0
                };
                Koha::Illrequestattribute->new($data)->store;
            }
        }
    }
}

=head3 prep_submission_metadata

Given a submission's metadata, probably from a form,
but maybe as an Illrequestattributes object,
and a partly constructed hashref, add any metadata that
is appropriate for this material type

=cut

sub prep_submission_metadata {
    my ($self, $metadata, $return) = @_;

    $return = $return //= {};

    my $metadata_hashref = {};

    if (ref $metadata eq "Koha::Illrequestattributes") {
        while (my $attr = $metadata->next) {
            $metadata_hashref->{$attr->type} = $attr->value;
        }
    } else {
        $metadata_hashref = $metadata;
    }

    # Get our canonical field list
    my $fields = $self->fieldmap;

    my $type = $metadata_hashref->{RapidRequestType};

    # Iterate our list of fields
    foreach my $field(keys %{$fields}) {
        # If this field is used in the selected material type and is populated
        if (
            grep( /^$type$/, @{$fields->{$field}->{materials}}) &&
            $metadata_hashref->{$field} &&
            length $metadata_hashref->{$field} > 0
        ) {
            # "array" fields need splitting by space and forming into an array
            if ($fields->{$field}->{type} eq 'array') {
                $metadata_hashref->{$field}=~s/  / /g;
                my @arr = split(/ /, $metadata_hashref->{$field});
                # Needs to be in the form
                # SuggestedIsbns => { string => [ "1234567890", "0987654321" ] }
                $return->{$field} = { string => \@arr };
            } else {
                $return->{$field} = $metadata_hashref->{$field};
            }
        }
    }

    return $return;
}

=head3 submit_and_request

Creates a local submission, then uses the returned ID to create
a RapidILL request

=cut

sub submit_and_request {
    my ($self, $params) = @_;

    # First we create a submission
    my $submission = $self->create_submission($params);

    # Now use the submission to try and create a request with Rapid
    return $self->create_request($submission);
}

=head3 create_request

Take a previously created submission and send it to RapidILL
in order to create a request

=cut

sub create_request {
    my ($self, $submission) = @_;

    # Add the ID of our newly created submission
    my $metadata = {
        XRefRequestId => $submission->illrequest_id
    };

    $metadata = $self->prep_submission_metadata(
        $submission->illrequestattributes,
        $metadata
    );

    # Make the request with RapidILL via the koha-plugin-rapidill API
    my $response = $self->{_api}->InsertRequest( $metadata, $submission->borrowernumber );

    # If the call to RapidILL was successful,
    # add the Rapid request ID to our submission's metadata
    my $body = from_json($response->decoded_content);
    if ($response->is_success && $body->{result}->{IsSuccessful}) {
        my $rapid_id = $body->{result}->{RapidRequestId};
        if ($rapid_id && length $rapid_id > 0) {
            Koha::Illrequestattribute->new({
                illrequest_id => $submission->illrequest_id,
                # Check required for compatibility with installations before bug 33970
                column_exists( 'illrequestattributes', 'backend' ) ? (backend =>"RapidILL") : (),
                type          => 'RapidRequestId',
                value         => $rapid_id
            })->store;
        }
        # Add the RapidILL ID to the orderid field
        $submission->orderid($rapid_id);
        # Update the submission status
        $submission->status('REQ')->store;

        # Log the outcome
        $self->log_request_outcome({
            outcome => 'RAPIDILL_REQUEST_SUCCEEDED',
            request => $submission
        });

        return { success => 1 };
    }
    # The call to RapidILL failed for some reason. Add the message we got back from the API
    # to the submission's Staff Notes
    $submission->notesstaff(
        join("\n\n", ($submission->notesstaff || "", "RapidILL request failed:\n" . $body->{result}->{VerificationNote} || ""))
    )->store;

    # Log the outcome
    $self->log_request_outcome({
        outcome => 'RAPIDILL_REQUEST_FAILED',
        request => $submission,
        message => $body->{result}->{VerificationNote}
    });

    # Return the message
    return {
        success => 0,
        message => $body->{result}->{VerificationNote}
    };

}

=head3 confirm

A wrapper around create_request allowing us to
provide the "confirm" method required by
the status graph

=cut

sub confirm {
    my ($self, $params) = @_;

    my $return = $self->create_request($params->{request});

    my $return_value = {
        cwd     => dirname(__FILE__),
        error   => 0,
        status  => "",
        message => "",
        method  => "create",
        stage   => "commit",
        next    => "illview",
        value   => {},
        %{$return}
    };

    return $return_value;
}

=head3 log_request_outcome

Log the outcome of a request to the RapidILL API

=cut

sub log_request_outcome {
    my ($self, $params) = @_;

    if ( $self->{_logger} ) {
        # TODO: This is a transitionary measure, we have removed set_data
        # in Bug 20750, so calls to it won't work. But since 20750 is
        # only in 19.05+, they only won't work in earlier
        # versions. So we're temporarily going to allow for both cases
        my $payload = {
            modulename   => 'ILL',
            actionname   => $params->{outcome},
            objectnumber => $params->{request}->id,
            infos        => to_json({
                log_origin => $self->name,
                response  => $params->{message}
            })
        };
        if ($self->{_logger}->can('set_data')) {
            $self->{_logger}->set_data($payload);
        } else {
            $self->{_logger}->log_something($payload);
        }
    }
}

=head3 get_log_template_path

    my $path = $BLDSS->get_log_template_path($action);

Given an action, return the path to the template for displaying
that action log

=cut

sub get_log_template_path {
    my ( $self, $action ) = @_;
    return $self->{templates}->{$action};
}

=head3 metadata

Return a hashref containing canonical values from the key/value
illrequestattributes store

=cut

sub metadata {
    my ( $self, $request ) = @_;

    my $attrs = $request->illrequestattributes;
    my $fields = $self->fieldmap;

    my $type = $attrs->find({ type => "RapidRequestType" })->value;

    my $metadata = {};

    while (my $attr = $attrs->next) {
        if ($fields->{$attr->type}) {
            my $label = ref $fields->{$attr->type}->{label} eq "HASH" ?
                $fields->{$attr->type}->{label}->{$type} :
                $fields->{$attr->type}->{label};
            $metadata->{$label} = $attr->value;
        }
    }

    # OPAC list view uses completely different property names for author
    # and title. Cater for that.
    if ($type eq "Article" || $type eq "BookChapter") {
        my $title_key = $fields->{ArticleTitle}->{label}->{$type};
        my $author_key = $fields->{ArticleAuthor}->{label}->{$type};
        $metadata->{Title} = $metadata->{$title_key} if $metadata->{$title_key};
        $metadata->{Author} = $metadata->{$author_key} if $metadata->{$author_key};
    } elsif ($type eq "Book") {
        $metadata->{Title} = $metadata->{'Book title'} if $metadata->{'Book title'};
        $metadata->{Author} = $metadata->{'Book author'} if $metadata->{'Book author'};
    }

    return $metadata;
}

=head3 capabilities

    $capability = $backend->capabilities($name);

Return the sub implementing a capability selected by NAME, or 0 if that
capability is not implemented.

=cut

sub capabilities {
    my ( $self, $name ) = @_;
    my ($query) = @_;
    my $capabilities = {
        # View and manage a request
        illview => sub { illview(@_); },
        # Migrate
        migrate => sub { $self->migrate(@_); },
        # Return whether we are ready to display availability
        should_display_availability => sub { _can_create_request(@_) }
    };
    return $capabilities->{$name};
}

=head3 _can_create_request

Given the parameters we've been passed, should we create the request

=cut

sub _can_create_request {
     my ($params) = @_;
     return ( defined $params->{'stage'} ) ? 1 : 0;
}


=head3 status_graph

This backend provides no additional actions on top of the core_status_graph

=cut

sub status_graph {
    return {
        EDITITEM => {
            prev_actions   => [ 'NEW' ],
            id             => 'EDITITEM',
            name           => 'Edited item metadata',
            ui_method_name => 'Edit item metadata',
            method         => 'edititem',
            next_actions   => [],
            ui_method_icon => 'fa-edit',
        },
        # Override REQ so we can rename the button
        # Talk about a sledgehammer to crack a nut
        REQ => {
            prev_actions   => [ 'NEW', 'REQREV', 'QUEUED', 'CANCREQ' ],
            id             => 'REQ',
            name           => 'Requested',
            ui_method_name => 'Request from RapidILL',
            method         => 'confirm',
            next_actions   => [ 'REQREV', 'COMP', 'CHK' ],
            ui_method_icon => 'fa-check',
        },
        MIG => {
            prev_actions =>
              [ 'NEW', 'REQ', 'GENREQ', 'REQREV', 'QUEUED', 'CANCREQ', ],
            id             => 'MIG',
            name           => 'Switched provider',
            ui_method_name => 'Switch provider',
            method         => 'migrate',
            next_actions   => [],
            ui_method_icon => 'fa-search',
        },        
    };
}

sub name {
    return "RapidILL";
}

=head3 _fail

=cut

sub _fail {
    my @values = @_;
    foreach my $val (@values) {
        return 1 if ( !$val or $val eq '' );
    }
    return 0;
}

=head3 find_rapid_property

Given a core property name, find the equivalent Rapid
name. Or undef if there is not one

=cut

sub find_rapid_property {
    my ($self, $core) = @_;
    my $fields = $self->fieldmap;
    foreach my $field(keys %{$fields}) {
        if ($fields->{$field}->{ill} && $fields->{$field}->{ill} eq $core) {
            return $field;
        }
    }
}

=head3 find_rapid_value

Given a Rapid property name and core value, find the equivalent Rapid
value. Or undef if there is not one

=cut

sub find_rapid_value {
    my ($self, $rapid_prop, $core_val) = @_;
    my $fields = $self->fieldmap;
    if ($fields->{$rapid_prop}->{value_map}) {
        my $map = $fields->{$rapid_prop}->{value_map};
        while (my($key, $value) = each%{$map}) {
            if ($map->{$key} eq $core_val) {
                return $key;
            }
        }
    }
}

=head3 _openurl_to_ill

Take a hashref of OpenURL parameters and return
those same parameters but transformed to the ILL
schema

=cut

sub _openurl_to_ill {
    my ($params) = @_;

    my $transform_metadata = {
        genre   => 'RapidRequestType',
        content => 'RapidRequestType',
        format  => 'RapidRequestType',
        atitle  => 'ArticleTitle',
        aulast  => 'ArticleAuthor',
        author  => 'ArticleAuthor',
        date    => 'PatronJournalYear',
        issue   => 'JournalIssue',
        volume  => 'JournalVol',
        isbn    => 'SuggestedIsbns',
        issn    => 'SuggestedIssns',
        rft_id  => '',
        year    => 'PatronJournalYear',
        title   => 'PatronJournalTitle',
        author  => 'ArticleAuthor',
        aulast  => 'ArticleAuthor',
        pages   => 'ArticlePages',
        ctitle  => 'ArticleTitle',
        clast   => 'ArticleAuthor'
    };

    my $transform_value = {
        RapidRequestType => {
            fulltext   => 'Article',
            selectedft => 'Article',
            print      => 'Book',
            ebook      => 'Book',
            journal    => 'Article'
        }
    };

    my $return = {};
    # First make sure our keys are correct
    foreach my $meta_key(keys %{$params->{other}}) {
        # If we are transforming this property...
        if (exists $transform_metadata->{$meta_key}) {
            # ...do it if we have valid mapping
            if (length $transform_metadata->{$meta_key} > 0) {
                $return->{$transform_metadata->{$meta_key}} = $params->{other}->{$meta_key};
            }
        } else {
            # Otherwise, pass it through untransformed
            $return->{$meta_key} = $params->{other}->{$meta_key};
        }
    }
    # Now check our values are correct
    foreach my $val_key(keys %{$return}) {
        my $value = $return->{$val_key};
        if (exists $transform_value->{$val_key} && exists $transform_value->{$val_key}->{$value}) {
            $return->{$val_key} = $transform_value->{$val_key}->{$value};
        }
    }
    $params->{other} = $return;
    return $params;
}

=head3 fieldmap_sorted

Return the fieldmap sorted by "order"
Note: The key of the field is added as a "key"
property of the returned hash

=cut

sub fieldmap_sorted {
    my ($self) = @_;

    my $fields = $self->fieldmap;

    my @out = ();

    foreach my $key (sort {
        $fields->{$a}->{position} <=> $fields->{$b}->{position}
    } keys %{$fields}) {
        my $el = $fields->{$key};
        $el->{key} = $key;
        push @out, $el;
    }

    return \@out;
}

=head3 fieldmap

All fields expected by the API

Key = API metadata element name
  exclude = Do not include on the entry form
  type = Does an element contain a string value or an array of string values?
  label = Display label
  ill   = The core ILL equivalent field
  help = Display help text
  value_map = Do the Rapid values need mapping to core values
  materials = Material types that expect this element (they may not *require* it)
 required = Hashref of material specific requirements
  Key = Material type that enforces this requirement
    group = Unique name for this grouo

Note regarding requirements: For any fields that are a member of a "group",
an "OR" requirement exists between members of that group
i.e. "You must complete field X OR field Y OR field Z"

=cut

sub fieldmap {
    return {
        RapidRequestType => {
            exclude   => 1,
            type      => "string",
            label     => "Material type",
            ill       => "type",
            position  => 99,
            value_map => {
                Book        => 'book',
                Article     => 'article',
                BookChapter => 'chapter'
            },
            materials => [ "Article", "Book", "BookChapter" ]
        },
        SuggestedIssns => {
            type      => "array",
            label     => "ISSN",
            ill       => "issn",
            position  => 11,
            help      => "Multiple ISSNs must be separated by a space",
            materials => [ "Article" ],
            required  => {
                "Article" => {
                    group   => "ARTICLE_IDENTIFIER"
                }
            }
        },
        OclcNumber => {
            type      => "string",
            label     => "OCLC Accession number",
            position  => 13,
            materials => [ "Article", "Book", "BookChapter" ],
            required  => {
                "Article" => {
                    group   => "ARTICLE_IDENTIFIER"
                },
                "Book" => {
                    group   => "BOOK_IDENTIFIER"
                }
            }
        },
        SuggestedIsbns => {
            type      => "array",
            label     => "ISBN",
            ill       => "isbn",
            position  => 10,
            help      => "Multiple ISBNs must be separated by a space",
            materials => [ "Book", "BookChapter" ],
            required  => {
                "Book" => {
                    group   => "BOOK_IDENTIFIER"
                }
            }
        },
        SuggestedLccns => {
            type      => "array",
            label     => "LCCN",
            position  => 12,
            help      => "Multiple LCCNs must be separated by a space",
            materials => [ "Book", "BookChapter" ]
        },
        ArticleTitle => {
            type      => "string",
            label     => {
                Article     => "Article title",
                BookChapter => "Book chapter title / number"
            },
            ill       => "article_title",
            position  => 1,
            materials => [ "Article", "BookChapter" ],
            required  => {
                "Article" => {
                    group   => "ARTICLE_ARTICLE_TITLE_PAGES"
                },
                "BookChapter" => {
                    group   => "CHAPTER_ARTICLE_TITLE_PAGES"
                }
            }
        },
        ArticleAuthor => {
            type      => "string",
            label     => {
                Article     => "Article author",
                Book        => "Book author",
                BookChapter => "Book author"
            },
            ill       => "article_author",
            position  => 2,
            materials => [ "Article", "Book", "BookChapter" ]
        },
        ArticlePages => {
            type      => "string",
            label     => {
                Article     => "Pages in journal",
                BookChapter => "Pages in book extract"
            },
            ill       => "pages",
            position  => 9,
            materials => [ "Article", "BookChapter" ],
            required  => {
                "Article" => {
                    group   => "ARTICLE_ARTICLE_TITLE_PAGES"
                },
                "BookChapter" => {
                    group   => "CHAPTER_ARTICLE_TITLE_PAGES"
                }
            }
        },
        PatronJournalTitle => {
            type      => "string",
            label     => {
                Article     => "Journal title",
                Book        => "Book title",
                BookChapter => "Book chapter title / number"
            },
            ill       => "title",
            position  => 0,
            materials => [ "Article", "Book", "BookChapter" ]
        },
        PatronJournalYear => {
            type      => "string",
            label     => "Four digit year of publication",
            ill       => "year",
            position  => 8,
            materials => [ "Article", "Book", "BookChapter" ],
            required  => {
                "Article" => {
                    group   => "ARTICLE_YEAR_VOL"
                }
            }
        },
        JournalVol => {
            type      => "string",
            label     => "Volume number",
            ill       => "volume",
            position  => 4,
            materials => [ "Article", "Book", "BookChapter" ],
            required  => {
                "Article" => {
                    group   => "ARTICLE_YEAR_VOL"
                }
            }
        },
        JournalIssue => {
            type      => "string",
            label     => "Journal issue number",
            ill       => "issue",
            position  => 5,
            materials => [ "Article" ]
        },
        JournalMonth => {
            type      => "string",
            ill       => "item_date",
            position  => 7,
            label     => "Journal month",
            materials => [ "Article" ]
        },
        Edition => {
            type      => "string",
            label     => "Book edition",
            ill       => "part_edition",
            position  => 3,
            materials => [ "Book", "BookChapter" ]
        },
        Publisher => {
            type      => "string",
            label     => "Book publisher",
            ill       => "publisher",
            position  => 6,
            materials => [ "Book", "BookChapter" ]
        },
        RapidRequestId => {
            exclude   => 1,
            type      => "string",
            ill       => "associated_id",
            label     => "RapidILL identifier",
            position  => 99,
            materials => [ "Article", "Book", "BookChapter" ]
        }
    };
}

=head3 _validate_borrower

=cut

sub _validate_borrower {

    # Perform cardnumber search.  If no results, perform surname search.
    # Return ( 0, undef ), ( 1, $brw ) or ( n, $brws )
    my ( $input, $action ) = @_;

    return ( 0, undef ) if !$input || length $input == 0;

    my $patrons = Koha::Patrons->new;
    my ( $count, $brw );
    my $query = { cardnumber => $input };
    $query = { borrowernumber => $input } if ( $action && $action eq 'search_results' );

    my $brws = $patrons->search($query);
    $count = $brws->count;
    my @criteria = qw/ surname userid firstname end /;
    while ( $count == 0 ) {
        my $criterium = shift @criteria;
        return ( 0, undef ) if ( "end" eq $criterium );
        $brws = $patrons->search( { $criterium => $input } );
        $count = $brws->count;
    }
    if ( $count == 1 ) {
        $brw = $brws->next;
    }
    else {
        $brw = $brws;    # found multiple results
    }
    return ( $count, $brw );
}


1;
