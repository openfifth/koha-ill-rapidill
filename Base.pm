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

use Koha::Illbackends::RapidILL::Lib::Config;
use Koha::Illbackends::RapidILL::Lib::API;
use Koha::Libraries;
use Koha::Patrons;

our $VERSION = "1.0.0";

sub new {
    my ($class, $params) = @_;

    my $config = Koha::Illbackends::RapidILL::Lib::Config->new( $params->{config} );
    my $api = Koha::Illbackends::RapidILL::Lib::API->new($config, $VERSION);

    my $self = {
        config  => $config,
        _api    => $api
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
        backend    => $self->name,
        method     => "create",
        stage      => $stage,
        branchcode => $other->{branchcode},
        cardnumber => $other->{cardnumber},
        status     => "",
        message    => "",
        error      => 0
    };

    # Check for borrowernumber
    if ( !$other->{borrowernumber} && defined( $other->{cardnumber} ) ) {
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

        # Pass the map of form fields in forms that can be used by TT
        # and JS
        $response->{field_map} = $self->fieldmap();
        $response->{field_map_json} = to_json($self->fieldmap());
        # We just need to request the snippet that builds the Creation
        # interface.
        $response->{stage} = 'init';
        $response->{value} = $params;
        return $response;
    }
    # Validate form and perform search if valid
    elsif ( $stage eq 'validate') {

        if ( _fail( $other->{'branchcode'} ) ) {
            # Pass the map of form fields in forms that can be used by TT
            # and JS
            $response->{field_map} = $self->fieldmap();
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
            $response->{field_map} = $self->fieldmap();
            $response->{field_map_json} = to_json($self->fieldmap());
            $response->{status} = "invalid_branch";
            $response->{error}  = 1;
            $response->{stage}  = 'init';
            $response->{value}  = $params;
            return $response;
        }
        elsif ( !$self->_validate_metadata($other) ) {
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
        method => "cancel",
        stage  => "init",
        error  => 1,
        message => $body->{result}->{VerificationNote}
    };
}

=head3 edititem

Edit an item's metadata

=cut

sub edititem {
    my ($self, $params) = @_;

    # Don't allow editing of requested submissions
    return { method => 'illlist' } if $params->{request}->status ne 'NEW';

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
            field_map => $self->fieldmap,
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
                field_map => $self->fieldmap,
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
                foreach my $field(%{$other}) {
                    my $value = $other->{$field};
                    if (
                        grep( /^$type$/, @{$fields->{$field}->{materials}}) &&
                        $other->{$field} &&
                        length $other->{$field} > 0
                    ) {
                        my @bind = ($submission->id, $field, $value, 0);
                        $dbh->do ( q|
                            INSERT INTO illrequestattributes
                            (illrequest_id, type, value, readonly) VALUES
                            (?, ?, ?, ?)
                        |, undef, @bind);
                    }
                }
            }
        );

        # Create response
        return {
            error          => 0,
            status         => '',
            message        => '',
            method         => 'create',
            stage          => 'commit',
            next           => 'illview',
            value          => $params,
            field_map      => $self->fieldmap,
            field_map_json => to_json($self->fieldmap)
        };
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
    return $request;
}

=head3

Store metadata for a given request

=cut

sub create_illrequestattributes {
    my ($self, $request, $metadata) = @_;

    # Get the canonical list of metadata fields
    my $fields = $self->fieldmap;

    my $type = $metadata->{RapidRequestType};
    # Iterate our list of fields
    foreach my $field (keys %{$fields}) {
        # If this field is used in the selected material type
        if (
            grep( /^$type$/, @{$fields->{$field}->{materials}}) &&
            $metadata->{$field} &&
            length $metadata->{$field} > 0
        ) {
            my $data = {
                illrequest_id => $request->illrequest_id,
                type          => $field,
                value         => $metadata->{$field},
                readonly      => 0
            };
            Koha::Illrequestattribute->new($data)->store;
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
                type          => 'RapidRequestId',
                value         => $rapid_id
            })->store;
        }
        # Update the submission status
        $submission->status('REQ')->store;
        return { success => 1 };
    }
    # The call to RapidILL failed for some reason. Add the message we got back from the API
    # to the submission's Staff Notes
    $submission->notesstaff(
        join("\n\n", ($submission->notesstaff || "", "RapidILL request failed:\n" . $body->{result}->{VerificationNote} || ""))
    )->store;
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

=head3 metadata

Return a hashref containing canonical values from the key/value
illrequestattributes store

=cut

sub metadata {
    my ( $self, $request ) = @_;

    my $attrs = $request->illrequestattributes;
    my $fields = $self->fieldmap;

    my $metadata = {};

    while (my $attr = $attrs->next) {
        $metadata->{$fields->{$attr->type}->{label}} = $attr->value;
    }

    return $metadata;
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

=head3 fieldmap

All fields expected by the API

Key = API metadata element name
  exclude = Do not include on the entry form
  type = Does an element contain a string value or an array of string values?
  label = Display label
  help = Display help text
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
            materials => [ "Article", "Book", "BookChapter" ]
        },
        SuggestedIssns => {
            type      => "array",
            label     => "ISSN",
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
            help      => "Multiple ISSNs must be separated by a space",
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
            help      => "Multiple LCCNs must be separated by a space",
            materials => [ "Book", "BookChapter" ]
        },
        ArticleTitle => {
            type      => "string",
            label     => "Article title or book chapter title / number",
            materials => [ "Article", "BookChapter" ],
            required  => {
                "BookChapter" => {
                    group   => "ARTICLE_TITLE_PAGES"
                }
            }
        },
        ArticleAuthor => {
            type      => "string",
            label     => "Article author or book author",
            materials => [ "Article", "Book", "BookChapter" ]
        },
        ArticlePages => {
            type      => "string",
            label     => "Pages in journal or book extract",
            materials => [ "Article", "BookChapter" ],
            required  => {
                "BookChapter" => {
                    group   => "ARTICLE_TITLE_PAGES"
                }
            }
        },
        PatronJournalTitle => {
            type      => "string",
            label     => "Journal title or book title",
            materials => [ "Article", "Book", "BookChapter" ]
        },
        PatronJournalYear => {
            type      => "string",
            label     => "Four digit year of publication",
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
            materials => [ "Article" ]
        },
        JournalMonth => {
            type      => "string",
            label     => "Journal month",
            materials => [ "Article" ]
        },
        Edition => {
            type      => "string",
            label     => "Book edition",
            materials => [ "Book", "BookChapter" ]
        },
        Publisher => {
            type      => "string",
            label     => "Book publisher",
            materials => [ "Book", "BookChapter" ]
        },
        RapidRequestId => {
            exclude   => 1,
            type      => "string",
            label     => "RapidILL identifier",
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