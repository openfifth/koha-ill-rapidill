package Koha::Illbackends::RapidILL::Processor::SendArticleLink;

use Modern::Perl;
use POSIX;

use parent qw(Koha::Illrequest::SupplierUpdateProcessor);

sub new {
    my ( $class ) = @_;
    my $self = $class->SUPER::new('backend', 'RapidILL', 'Send article link');
    bless $self, $class;
    return $self;
}

sub run {
    my ( $self, $update, $options, $status ) = @_;
    # Parse the update
    # Look for the pertinent elements
    # Create a notice
    # Queue the notice
    # Add an update to the staff notes with timestamp of notice creation
    # Update the request status and status_alias as appropriate
    $self->{do_debug} = $options->{debug};
    $self->{dry_run} = $options->{dry_run};
    my $update_body = $update->{update};
    my $request = $update->{request};

    # Get the elements we need
    my $address = $update_body->{ArticleExchangeAddress};
    my $password = $update_body->{ArticleExchangePassword};

    # If we've not got what we need, record that fact and bail
    if (!$address || length $address == 0 || !$password || length $password == 0) {
        push @{$status->{error}}, "Unable to access article address and/or password";
        return $status;
    }

    my $update_text = <<"END_MESSAGE";
    Your request has been fulfilled, it can be accessed here:
    URL: $address
    Password: $password
END_MESSAGE

    # Try to send the notice if appropriate
    my $ret;
    if (!$options->{dry_run}) {
        $self->debug_msg('Sending patron notice');
        $ret = $request->send_patron_notice(
            'ILL_REQUEST_UPDATE',
            $update_text
        );
    } else {
        $self->debug_msg('Sending patron notice');
        $ret = { result => { success => [ 'DRY RUN '] } };
    }

    my $timestamp = POSIX::strftime("%d/%m/%Y %H:%M:%S\n", localtime);
    # Update the passed hashref with how we got on
    if ($ret->{result} && $ret->{result}->{success} && scalar @{$ret->{result}->{success}} > 0) {
        # Record success
        push @{$status->{success}}, join(',', @{$ret->{result}->{success}});
        $self->debug_msg('Appending fulfilment message to staff note');
        if (!$options->{dry_run}) {
            # Add a note to the request
            $request->append_to_note("Fulfilment notice sent to patron at $timestamp");
        }
        # Set the status as appropriate
        if (length $options->{status_to} > 0) {
            $self->debug_msg("Setting request status to " . $options->{status_to});
            if (!$options->{dry_run}) {
                $request->status($options->{status_to})->store;
            }
        }
        if (length $options->{status_alias_to} > 0) {
            $self->debug_msg("Setting request status alias to " . $options->{status_alias_to});
            if (!$options->{dry_run}) {
                $request->status_alias($options->{status_alias_to})->store;
            }
        }
    }
    if ($ret->{result} && $ret->{result}->{fail} && scalar @{$ret->{result}->{fail}} > 0) {
        # Record the problem
        push @{$status->{error}}, join(',', @{$ret->{result}->{fail}});
        # Add a note to the request
        $self->debug_msg('Appending failed fulfilment message to staff note');
        if (!$options->{dry_run}) {
            $request->append_to_note("Unable to send fulfilment notice to patron at $timestamp");
        }
    }
}

sub debug_msg {
    my ( $self, $msg ) = @_;
    if ($self->{do_debug} && ref $self->{do_debug} eq 'CODE') {
        &{$self->{do_debug}}($self->{dry_run} ? "DRY RUN: $msg" : $msg);
    }
};

1;