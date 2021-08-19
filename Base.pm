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

use CGI;
use JSON qw( to_json );

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
        cgi     => new CGI,
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
            my $result = $self->create_request($params);

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
        return { success => 1};
    }

    # This submission was submitted to Rapid, so we can try to cancel it there
    my $response = $self->{_api}->UpdateRequest(
        $rapid_request_id,
        "Cancel"
    );

    # If the cancellation was successful, note that in Staff notes
    if ($response->{parameters}->{UpdateRequestResult}->{IsSuccessful}) {
        $params->{request}->notesstaff(
            join("\n\n", ($params->{request}->notesstaff || "", "Cancelled with RapidILL"))
        )->store;
        return { success => 1};
    }

    # Return the failure message
    return {
        success => 0,
        message => $response->{parameters}->{UpdateRequestResult}->{VerificationNote}
    };
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

sub create_illrequestattributes {
    my ($self, $request, $metadata) = @_;

    # Get the canonical list of metadata fields
    my $fields = $self->fieldmap;

    my $type = $metadata->{RapidRequestType};
    # Iterate our list of fields
    foreach my $field (keys %{$fields}) {
        # If this field is used in the selected material type
        if ( grep( /^$type$/, @{$fields->{$field}->{materials}})) {
            my $data = {
                illrequest_id => $request->illrequest_id,
                type          => $field,
                value         => $metadata->{$field}
            };
            Koha::Illrequestattribute->new($data)->store;
        }
    }
}

=head3 create_request

Creates a local submission, then uses the returned ID to create
a RapidILL request

=cut

sub create_request {
    my ($self, $params) = @_;

    # First we create a submission, we can then pass the local request
    # ID to Rapid.
    my $submission = $self->create_submission($params);

    my $fields = $self->fieldmap;
    my $type = $params->{other}->{RapidRequestType};

    # Add the ID of our newly created submission
    my $metadata = {
        XRefRequestId => $submission->illrequest_id
    };

    # Iterate our list of fields
    foreach my $field(keys %{$fields}) {
        # If this field is used in the selected material type and is populated
        if ( grep( /^$type$/, @{$fields->{$field}->{materials}}) && length $params->{other}->{$field} > 0) {
            # "array" fields need splitting by space and forming into an array
            if ($fields->{$field}->{type} eq 'array') {
                my @arr = split(/ /, $params->{other}->{$field});
                # FIXME: The WSDL defines certain fields (SuggestedIssns, SuggestedIsbns etc.) as an array:
                #
                # <SuggestedIssns>
                #     <string>0028-0836</string>
                #     <string>1476-4687</string>
                # </SuggestedIssns>
                #
                # However, this needs to be represented as a hash, rather than an array
                # Trying to build it as:
                # 
                # SuggestedIssns => [ { string => "0028-0836" }, { string => "1476-4687" } ]
                # 
                # results in:
                #
                # error: complex `tns:SuggestedIssns' requires a HASH of input data, not `ARRAY' at tns:InsertRequest/input/SuggestedIssns
                #
                # I don't know how to represent this as a hash, clearly I can't have a hash with multiple "string" keys
                # so the code below only uses the first value. I've emailed the developer of XML::Compile::WSDL11 for suggestions.
                my $values = {
                    string => $arr[0]
                };
                $metadata->{$field} = $values;
            } else {
                $metadata->{$field} = $params->{other}->{$field};
            }
        }
    }
    
    # Make the request
    my $response = $self->{_api}->InsertRequest( $metadata, $self->{borrower} );

    # If the call to RapidILL was successful,
    # add the Rapid request ID to our submission's metadata
    if ($response->{parameters}->{InsertRequestResult}->{IsSuccessful}) {
        my $rapid_id = $response->{parameters}->{InsertRequestResult}->{RapidRequestId};
        if ($rapid_id) {
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
        join("\n\n", ($submission->notesstaff || "", "RapidILL request failed:\n" . $response->{parameters}->{InsertRequestResult}->{VerificationNote}))
    )->store;
    # Return the message
    return {
        success => 0,
        message => $response->{parameters}->{InsertRequestResult}->{VerificationNote}
    };
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
    return {};
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