package Plugins::PersistentIDs::Plugin;

#
# LMS Persistent IDs
#
# (c) 2026 Craig Drummond
#
# Licence: GPL v3
#

use strict;

use Slim::Utils::Log;

use Plugins::PersistentIDs::Importer;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.persistentids',
    'defaultLevel' => 'ERROR',
    'logGroups'    => 'SCANNER',
});

my $initialized = 0;

sub initPlugin {
    my $class = shift;

    return 1 if $initialized;

    $initialized = 1;
    return $initialized;
}

sub postinitPlugin {
    my $class = shift;
}

1;

__END__
