package Koha::Illbackends::RapidILL::Lib::Config;

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

use Carp qw( croak );

=head3 new

my $config = Koha::Illbackends::RapidILL::Lib::Config->new(
    {
        username               => "username",
        password               => "password",
        requesting_rapid_code  => "requesting_rapid_code",
        requesting_branch_name => "requesting_branch_name"
    }
);

Constructor for RapidILL Config object. All hashref values are required
and should be specified in koha-conf.xml as:
<interlibrary_loans>
    <rapid_ill>
        <username>username</username>
        <password>password</password>
        <requesting_rapid_code>requesting_rapid_code</requesting_rapid_code>
        <requesting_branch_name>requesting_branch_name</requesting_branch_name>
    </rapid_ill>
</interlibrary_loans>

=cut

sub new {
    my ($class, $configuration) = @_;

    my $config = $configuration->{configuration}->{raw_config};

    # Check the config is defined
    my @config_params = (
        "username",
        "password",
        "requesting_rapid_code",
        "requesting_branch_name"
    );
    if (!_validate_config($config, \@config_params)) {
        croak "Invalid config";
    }

    # Extract the config elements we need
    my $rapid_config = _get_config($config, \@config_params);

    my $self = {
        %{$rapid_config}
    };

    bless $self, $class;
    return $self;
}

sub config {
    my $self = shift;
    return $self->{config};
}

=head3

Validate that the config has the keys we expect and there is something
specified as a value

=cut

sub _validate_config {
    my ($config, $required) = @_;

    my $valid = 0;

    foreach my $val(@{$required}) {
        if ($config->{rapid_ill}->{$val} && length $config->{rapid_ill}->{$val} > 0) {
            $valid++;
        }
    }

    return $valid == scalar @{$required};
}

=head3 

Get the config elements we need

=cut

sub _get_config {
    my ($config, $required) = @_;

    my $return = {};

    foreach my $val(@{$required}) {
        $return->{$val} = $config->{rapid_ill}->{$val};
    }

    return $return
}

1;