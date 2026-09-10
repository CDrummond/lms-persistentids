#
# LMS Persistent IDs
#
# (c) 2026 Craig Drummond
#
# Licence: GPL v3
#

package Plugins::PersistentIDs::Importer;

use strict;
use warnings;
use utf8;
use DBI;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Schema;
use File::Copy;

use constant CURR_NAME     => "library.db";
use constant PREV_NAME     => "library-prev.db";
use constant WRITE_CHANGES => 1;

my $log = Slim::Utils::Log::logger('plugin.persistentids');
my $serverprefs = preferences('server');

my %tracks = ();
my %contributors = ();
my %albums = ();
my %genres = ();
my %works = ();

sub initPlugin {
    main::INFOLOG && $log->is_info && $log->info('Init');
    Slim::Music::Import->addImporter('Plugins::PersistentIDs::Importer', {
        'type' => 'post',
        'weight' => 0,
        'use' => 1,
    });
    if (main::SCANNER) {
        if (Slim::Music::Import->stillScanning() eq 'SETUP_WIPEDB') {
            main::INFOLOG && $log->is_info && $log->info('Is a wipe-scan, so copy DB before its wiped');
            my $dbDir = $serverprefs->get('cachedir');
            my $currPath = $dbDir . "/" . CURR_NAME;
            my $prevPath = $dbDir . "/" . PREV_NAME;
            if (-e $prevPath) {
                unlink($prevPath);
            }
            if (-e $currPath) {
                _copyDb($currPath, $prevPath);
            }
        } else {
            main::INFOLOG && $log->is_info && $log->info('Not a wipe-scan, so no need to restore IDs');
        }
    }
}

sub startScan {
    if (main::SCANNER) {
        my $class = shift;
        my $dbDir = $serverprefs->get('cachedir');
        my $currPath = $dbDir . "/" . CURR_NAME;
        my $prevPath = $dbDir . "/" . PREV_NAME;
        if ((-e $currPath) && (-e $prevPath)) {
            main::INFOLOG && $log->is_info && $log->info('Starting ID re-write');
            my $currDbh = DBI->connect( "dbi:SQLite:dbname=${currPath}", '', '', { RaiseError => 1, AutoCommit => 0 });
            my $prevDbh = DBI->connect( "dbi:SQLite:dbname=${prevPath}", '', '', { RaiseError => 0 });
            my $seqs = _readPreviousSequences($prevDbh);
            eval {
                my $isWipe = _checkIfWipe($currDbh, $seqs);
                if ($isWipe>0) {
                    _setIds($currDbh, $prevDbh, $seqs);
                } else {
                    main::INFOLOG && $log->is_info && $log->info('Not a clear-all scan, so no need to restore IDs');
                }
            };
            if ($@) {
                $log->is_error && $log->error("Failed to update IDs, rolling back any changes: $@");
                eval { $currDbh->rollback(); }
            }

            $currDbh->disconnect();
            $prevDbh->disconnect();
            main::INFOLOG && $log->is_info && $log->info("Finished");
        } else {
            main::INFOLOG && $log->is_info && $log->info('DBs not found');
        }
        if (-e $prevPath) {
            unlink($prevPath);
        }
        Slim::Music::Import->endImporter($class);
    }
}

sub _readPreviousSequences {
    my ($dbh) = @_;
    main::INFOLOG && $log->is_info && $log->info("Read sequence values from previous DB");
    my $sql = $dbh->prepare( qq{SELECT name, seq FROM sqlite_sequence} );
    my %seqs = ();
    $sql->execute();
    if ( my $result = $sql->fetchall_arrayref({}) ) {
        foreach my $res (@$result) {
            my $name = $res->{'name'};
            my $seq = int($res->{'seq'} || 0);
            $seqs{$name} = $seq;
            main::INFOLOG && $log->is_info && $log->info(" ... ${name} -> ${seq}");
        }
    }
    $sql->finish();
    return \%seqs;
}

sub _checkIfWipe {
    my ($dbh, $seqs) = @_;
    main::INFOLOG && $log->is_info && $log->info("Check if this is a clear-all scan");

    my @keys = ("contributors", "albums", "tracks", "genres", "works", "playlist_track", "comments");
    foreach my $key (@keys) {
        my $sql = $dbh->prepare( qq{SELECT MIN(id) FROM ${key} LIMIT 1} );
        $sql->execute();
        my $result = $sql->fetchrow_array();
        if (defined $result) {
            my $val = int($result);
            if ($val < $seqs->{$key}) {
                main::INFOLOG && $log->is_info && $log->info("Found a ${key} ID less then sequence. (${val} < $seqs->{$key})");
                $sql->finish();
                return 0;
            }
        }
        $sql->finish();
    }
    return 1;
}

sub _copyDb {
    my ($src, $dest) = @_;
    my $dbh = DBI->connect("dbi:SQLite:dbname=${src}", "", "", { RaiseError => 0 });

    # VACUUM INTO creates a consistent, compacted copy
    $dbh->do("VACUUM INTO '${dest}'");
    $dbh->disconnect();
}

sub _setNewIds {
    my ($dbh, $table, $start, $idHash) = @_;
    my @ids = ();
    my $sql = $dbh->prepare( qq{SELECT id FROM ${table} WHERE id>${start} ORDER BY id} );
    $sql->execute();
    if ( my $result = $sql->fetchall_arrayref({}) ) {
        foreach my $res (@$result) {
            my $id = $res->{'id'};
            push(@ids, $id);
        }
    }
    $sql->finish();
    if (@ids) {
        main::INFOLOG && $log->is_info && $log->info("UPDATING current IDS for ${table}");
        foreach my $id (@ids) {
            $start += 1;
            if ($id > $start) {
                main::DEBUGLOG && $log->is_debug && $log->debug("CHANGE ${table} ${id} -> ${start}");
                if (WRITE_CHANGES) {
                    my $usql = $dbh->prepare_cached( qq{UPDATE $table SET id = ? WHERE id = ?} );
                    $usql->execute($id, $start);
                    $usql->finish();
                }
                $idHash->{$id} = $start;
            }
        }
    }
}

sub _updateTable {
    my ($dbh, $table, $column, $from, $to) = @_;
    my $sql = $dbh->prepare_cached( qq{UPDATE ${table} SET ${column} = ? WHERE ${column} = ?} );
    $sql->execute($to, $from);
    $sql->finish;
}

sub _tableExists {
    my ($dbh, $table) = @_;
    my $sql = $dbh->prepare("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' aND name =?");
    $sql->execute($table);
    my $count = $sql->fetchrow_array();
    $sql->finish;
    return $count > 0;
}

sub _updateSequence {
    my ($dbh, $table) = @_;
    my $sql = $dbh->prepare( qq{SELECT MAX(id) FROM ${table} LIMIT 1} );
    $sql->execute();
    my $result = $sql->fetchrow_array();
    $sql->finish();
    if (defined $result) {
        if (WRITE_CHANGES) {
            my $usql = $dbh->prepare_cached( qq{UPDATE sqlite_sequence SET seq = ? WHERE name = ?} );
            $usql->execute($result, $table);
            $usql->finish();
        }
    }
}

sub _setIds {
    my ($currDbh, $prevDbh, $seqs) = @_;
    main::INFOLOG && $log->is_info && $log->info("Restore IDs");

    $currDbh->do('PRAGMA foreign_keys = OFF');

    #
    # First of all reset any IDs to previous values...
    #

    # Keep track of current->prev ID changes
    my %currTrackIdsToPrev = ();
    my %prevTrackIdsToCurr = ();
    my %currContribIdsToPrev = ();
    my %prevContribIdsToCurr = ();
    my %currAlbumIdsToPrev = ();
    my %currGenreIdsToPrev = ();
    my %currWorkIdsToPrev = ();
    my %currPlaylistTrackIdsToPrev = ();
    my %currCommentIdsToPrev = ();
    my $changed = 0;

    # Tracks
    main::INFOLOG && $log->is_info && $log->info("Restore track IDs");
    my $sql = $prevDbh->prepare( qq{SELECT id, url FROM tracks ORDER BY id} );
    $sql->execute();
    if ( my $result = $sql->fetchall_arrayref({}) ) {
        foreach my $res (@$result) {
            my $id = int($res->{'id'});
            my $url = $res->{'url'};
            my $csql = $currDbh->prepare_cached( qq{SELECT id FROM tracks WHERE url = ? LIMIT 1} );
            $csql->execute($url);
            my $result = $csql->fetchrow_array();
            if (defined $result) {
                my $cid = int($result);
                if ($cid != $id) {
                    $currTrackIdsToPrev{$cid} = $id;
                    $prevTrackIdsToCurr{$id} = $cid;
                    main::DEBUGLOG && $log->is_debug && $log->debug("TRACK ${url} :: ${cid} -> ${id}");
                    if (WRITE_CHANGES) {
                        my $usql = $currDbh->prepare_cached( qq{UPDATE tracks SET id = ? WHERE id = ?} );
                        $usql->execute($id, $cid);
                        $usql->finish();
                    }
                } else {
                    main::DEBUGLOG && $log->is_debug && $log->debug("TRACK NO CHANGE ${url} :: ${id}");
                }
            }
            $csql->finish();
        }
    }
    $sql->finish();

    # Artists
    main::INFOLOG && $log->is_info && $log->info("Restore artist IDs");
    $sql = $prevDbh->prepare( qq{SELECT id, musicbrainz_id, name FROM contributors ORDER BY id} );
    $sql->execute();
    if ( my $result = $sql->fetchall_arrayref({}) ) {
        foreach my $res (@$result) {
            my $mbid = $res->{'musicbrainz_id'};
            my $id = int($res->{'id'});
            my $name = $res->{'name'};
            if ($mbid) {
                my $csql = $currDbh->prepare_cached( qq{SELECT id FROM contributors WHERE musicbrainz_id = ? LIMIT 1} );
                $csql->execute($mbid);
                my $result = $csql->fetchrow_array();
                if (defined $result) {
                    my $cid = int($result);
                    if ($cid != $id) {
                        $currContribIdsToPrev{$cid} = $id;
                        $prevContribIdsToCurr{$id} = $cid;
                        main::DEBUGLOG && $log->is_debug && $log->debug("ARTIST ${mbid} :: ${cid} -> ${id}");
                        if (WRITE_CHANGES) {
                            my $usql = $currDbh->prepare_cached( qq{UPDATE contributors SET id = ? WHERE id = ?} );
                            $usql->execute($id, $cid);
                            $usql->finish();
                        }
                    } else {
                        main::DEBUGLOG && $log->is_debug && $log->debug("ARTIST NO CHANGE ${mbid} -> ${id}");
                    }
                }
                $csql->finish();
            } else {
                my $csql = $currDbh->prepare_cached( qq{SELECT id FROM contributors WHERE name = ? LIMIT 1} );
                $csql->execute($name);
                my $result = $csql->fetchrow_array();
                if (defined $result) {
                    my $cid = int($result);
                    if ($cid != $id) {
                        $currContribIdsToPrev{$cid} = $id;
                        $prevContribIdsToCurr{$id} = $cid;
                        main::DEBUGLOG && $log->is_debug && $log->debug("ARTIST ${name} :: ${cid} -> ${id}");
                        if (WRITE_CHANGES) {
                            my $usql = $currDbh->prepare_cached( qq{UPDATE contributors SET id = ? WHERE id = ?} );
                            $usql->execute($id, $cid);
                            $usql->finish();
                        }
                    } else {
                        main::DEBUGLOG && $log->is_debug && $log->debug("ARTIST NO CHANGE ${name} :: ${id}");
                    }
                }
                $csql->finish();
            }
        }
    }
    $sql->finish();

    # Albums
    main::INFOLOG && $log->is_info && $log->info("Restore album IDs");
    $sql = $prevDbh->prepare( qq{SELECT id, musicbrainz_id, title, year, disc, contributor FROM albums ORDER BY id} );
    $sql->execute();
    if ( my $result = $sql->fetchall_arrayref({}) ) {
        foreach my $res (@$result) {
            my $mbid = $res->{'musicbrainz_id'};
            my $id = int($res->{'id'});
            my $title = $res->{'title'};
            my $year = $res->{'year'};
            my $disc = $res->{'disc'};
            my $contributor = $res->{'contributor'};

            if ($mbid) {
                my $csql = $currDbh->prepare_cached( qq{SELECT id FROM albums WHERE musicbrainz_id = ? LIMIT 1} );
                $csql->execute($mbid);
                my $result = $csql->fetchrow_array();
                if (defined $result) {
                    my $cid = int($result);
                    if ($cid != $id) {
                        $currAlbumIdsToPrev{$cid} = $id;
                        main::DEBUGLOG && $log->is_debug && $log->debug("ALBUM ${mbid} :: ${cid} -> ${id}");
                        if (WRITE_CHANGES) {
                            my $usql = $currDbh->prepare_cached( qq{UPDATE albums SET id = ? WHERE id = ?} );
                            $usql->execute($id, $cid);
                            $usql->finish();
                        }
                    } else {
                        main::DEBUGLOG && $log->is_debug && $log->debug("ALBUM NO CHANGE ${mbid} :: ${id}");
                    }
                }
            } else {
                my $contribId = exists($prevContribIdsToCurr{$contributor}) ? $prevContribIdsToCurr{$contributor} : $contributor;
                my $dbg = "";
                my $csql = undef;
                if ($year && $disc) {
                    $dbg="${title}/${year}/${disc}/${contribId}";
                    $csql = $currDbh->prepare_cached( qq{SELECT id FROM albums WHERE title = ? AND year = ? AND disc = ? AND contributor = ? LIMIT 1} );
                    $csql->execute($title, $year, $disc, $contribId);
                } elsif ($year) {
                    $dbg="${title}/${year}/${contribId}";
                    $csql = $currDbh->prepare_cached( qq{SELECT id FROM albums WHERE title = ? AND year = ? AND contributor = ? LIMIT 1} );
                    $csql->execute($title, $year, $contribId);
                } elsif ($disc) {
                    $dbg="${title}/${disc}/${contribId}";
                    $csql = $currDbh->prepare_cached( qq{SELECT id FROM albums WHERE title = ? AND disc = ? AND contributor = ? LIMIT 1} );
                    $csql->execute($title, $disc, $contribId);
                } else {
                    $dbg="${title}/${contribId}";
                    $csql = $currDbh->prepare_cached( qq{SELECT id FROM albums WHERE title = ? AND contributor = ? LIMIT 1} );
                    $csql->execute($title, $contribId);
                }
                my $result = $csql->fetchrow_array();
                if (defined $result) {
                    my $cid = int($result);
                    if ($cid != $id) {
                        $currAlbumIdsToPrev{$cid} = $id;
                        main::DEBUGLOG && $log->is_debug && $log->debug("ALBUM ${dbg} :: ${cid} -> ${id}");
                        if (WRITE_CHANGES) {
                            my $usql = $currDbh->prepare_cached( qq{UPDATE albums SET id = ? WHERE id = ?} );
                            $usql->execute($id, $cid);
                            $usql->finish();
                        }
                    } else {
                        main::DEBUGLOG && $log->is_debug && $log->debug("ALBUM NO CHANGE ${dbg} :: ${id}");
                    }
                }
                $csql->finish();
            }
        }
    }
    $sql->finish();

    # Genres
    main::INFOLOG && $log->is_info && $log->info("Restore genre IDs");
    $sql = $prevDbh->prepare( qq{SELECT id, name FROM genres ORDER BY id} );
    $sql->execute();
    if ( my $result = $sql->fetchall_arrayref({}) ) {
        foreach my $res (@$result) {
            my $id = int($res->{'id'});
            my $name = $res->{'name'};
            my $csql = $currDbh->prepare_cached( qq{SELECT id FROM genres WHERE name = ? LIMIT 1} );
            $csql->execute($name);
            my $result = $csql->fetchrow_array();
            if (defined $result) {
                my $cid = int($result);
                if ($cid != $id) {
                    $currGenreIdsToPrev{$cid} = $id;
                    main::DEBUGLOG && $log->is_debug && $log->debug("GENRE ${name} :: ${cid} -> ${id}");
                    if (WRITE_CHANGES) {
                        my $usql = $currDbh->prepare_cached( qq{UPDATE genres SET id = ? WHERE id = ?} );
                        $usql->execute($id, $cid);
                        $usql->finish();
                    }
                } else {
                    main::DEBUGLOG && $log->is_debug && $log->debug("GENRE NO CHANGE ${name} :: ${id}");
                }
            }
            $csql->finish();
        }
    }
    $sql->finish();

    # Works
    main::INFOLOG && $log->is_info && $log->info("Restore work IDs");
    $sql = $prevDbh->prepare( qq{SELECT id, composer, title FROM works ORDER BY id} );
    $sql->execute();
    if ( my $result = $sql->fetchall_arrayref({}) ) {
        foreach my $res (@$result) {
            my $id = int($res->{'id'});
            my $composer = $res->{'composer'};
            my $title = $res->{'title'};
            my $composerId = exists($prevContribIdsToCurr{$composer}) ? $prevContribIdsToCurr{$composer} : $composer;
            my $csql = $currDbh->prepare_cached( qq{SELECT id FROM works WHERE composer = ? AND title = ? LIMIT 1} );
            $csql->execute($composerId, $title);
            my $result = $csql->fetchrow_array();
            if (defined $result) {
                my $cid = int($result);
                if ($cid != $id) {
                    $currWorkIdsToPrev{$cid} = $id;
                    main::DEBUGLOG && $log->is_debug && $log->debug("WORK ${composer}:${composerId}/${title} :: ${cid} -> ${id}");
                    if (WRITE_CHANGES) {
                        my $usql = $currDbh->prepare_cached( qq{UPDATE works SET id = ? WHERE id = ?} );
                        $usql->execute($id, $cid);
                        $usql->finish();
                    }
                } else {
                    main::DEBUGLOG && $log->is_debug && $log->debug("WORK NO CHANGE ${composer}:${composerId}/${title} :: ${id}");
                }
            }
            $csql->finish();
        }
    }
    $sql->finish();


    # Playlist Tracks
    main::INFOLOG && $log->is_info && $log->info("Restore playlist-track IDs");
    $sql = $prevDbh->prepare( qq{SELECT id, position, playlist, track FROM playlist_track ORDER BY id} );
    $sql->execute();
    if ( my $result = $sql->fetchall_arrayref({}) ) {
        foreach my $res (@$result) {
            my $id = int($res->{'id'});
            my $position = int($res->{'position'});
            my $playlist = $res->{'playlist'};
            my $track = $res->{'track'};
            if (exists $prevTrackIdsToCurr{$playlist}) {
                my $playlistId = $prevTrackIdsToCurr{$playlist};
                my $csql = $currDbh->prepare_cached( qq{SELECT id FROM playlist_track WHERE playlist = ? AND position = ? AND track = ? LIMIT 1} );
                $csql->execute($playlistId, $position, $track);
                my $result = $csql->fetchrow_array();
                if (defined $result) {
                    my $cid = int($result);
                    if ($result != $id) {
                        $currPlaylistTrackIdsToPrev{$cid} = $id;
                        main::DEBUGLOG && $log->is_debug && $log->debug("PLAYLIST_TRACK ${playlist}:${playlistId}/${track} :: ${cid} -> ${id}");
                        if (WRITE_CHANGES) {
                            my $usql = $currDbh->prepare_cached( qq{UPDATE playlist_track SET id = ? WHERE id = ?} );
                            $usql->execute($id, $cid);
                            $usql->finish();
                        }
                    } else {
                        main::DEBUGLOG && $log->is_debug && $log->debug("PLAYLIST_TRACK NO CHANGE ${playlist}:${playlistId}/${track} :: ${id}");
                    }
                }
                $csql->finish();
            }
        }
    }
    $sql->finish();

    # Comments
    main::INFOLOG && $log->is_info && $log->info("Restore comment IDs");
    $sql = $prevDbh->prepare( qq{SELECT id, track, value FROM comments ORDER BY id} );
    $sql->execute();
    if ( my $result = $sql->fetchall_arrayref({}) ) {
        foreach my $res (@$result) {
            my $id = int($res->{'id'});
            my $track = $res->{'track'};
            my $value = $res->{'value'};
            my $trackId = exists($prevTrackIdsToCurr{$track}) ? $prevTrackIdsToCurr{$track} : $track;
            my $csql = $currDbh->prepare_cached( qq{SELECT id FROM comments WHERE track = ? AND value = ? LIMIT 1} );
            $csql->execute($trackId, $value);
            my $result = $csql->fetchrow_array();
            if (defined $result) {
                my $cid = int($result);
                if ($cid != $id) {
                    $currCommentIdsToPrev{$cid} = $id;
                    main::DEBUGLOG && $log->is_debug && $log->debug("COMMENT ${track}:${trackId} :: ${cid} -> ${id}");
                    if (WRITE_CHANGES) {
                        my $usql = $currDbh->prepare_cached( qq{UPDATE comments SET id = ? WHERE id = ?} );
                        $usql->execute($id, $cid);
                        $usql->finish();
                    }
                } else {
                    main::DEBUGLOG && $log->is_debug && $log->debug("COMMENT NO CHANGE ${track}:${trackId} :: ${id}");
                }
            }
            $csql->finish();
        }
    }
    $sql->finish();

    #
    # Try to reduce range of new IDS...
    #

    main::INFOLOG && $log->is_info && $log->info("Re-assign any new IDs");
    if (%currTrackIdsToPrev) {
        _setNewIds($currDbh, "tracks", $seqs->{"tracks"}, \%currTrackIdsToPrev);
    }
    if (%currContribIdsToPrev) {
        _setNewIds($currDbh, "contributors", $seqs->{"contributors"}, \%currContribIdsToPrev);
    }
    if (%currAlbumIdsToPrev) {
        _setNewIds($currDbh, "albums", $seqs->{"albums"}, \%currAlbumIdsToPrev);
    }
    if (%currGenreIdsToPrev) {
        _setNewIds($currDbh, "genres", $seqs->{"genres"}, \%currGenreIdsToPrev);
    }
    if (%currWorkIdsToPrev) {
        _setNewIds($currDbh, "works", $seqs->{"works"}, \%currWorkIdsToPrev);
    }
    if (%currPlaylistTrackIdsToPrev) {
        _setNewIds($currDbh, "playlist_track", $seqs->{"playlist_track"}, \%currPlaylistTrackIdsToPrev);
    }
    if (%currCommentIdsToPrev) {
        _setNewIds($currDbh, "comments", $seqs->{"comments"}, \%currCommentIdsToPrev);
    }

    #
    # Update any tables that might reference changed IDS..
    #

    if (%currTrackIdsToPrev) {
        main::INFOLOG && $log->is_info && $log->info("Update track IDs in other tables");
        my $haveMLibTrack = _tableExists($currDbh, "multilibrary_track");
        foreach my $key (keys %currTrackIdsToPrev) {
            my $to = $currTrackIdsToPrev{$key};
            _updateTable($currDbh, "comments", "track", $key, $to);
            _updateTable($currDbh, "contributor_track", "track", $key, $to);
            _updateTable($currDbh, "genre_track", "track", $key, $to);
            _updateTable($currDbh, "library_track", "track", $key, $to);
            _updateTable($currDbh, "playlist_track", "playlist", $key, $to);
            if ($haveMLibTrack) {
                _updateTable($currDbh, "multilibrary_track", "track", $key, $to);
            }
        }
    }

    if (%currContribIdsToPrev) {
        main::INFOLOG && $log->is_info && $log->info("Update artist IDs in other tables");
        my $haveMLibContrib = _tableExists($currDbh, "multilibrary_contributor");
        foreach my $key (keys %currContribIdsToPrev) {
            my $to = $currContribIdsToPrev{$key};
            _updateTable($currDbh, "tracks", "primary_artist", $key, $to);
            _updateTable($currDbh, "albums", "contributor", $key, $to);
            _updateTable($currDbh, "contributor_album", "contributor", $key, $to);
            _updateTable($currDbh, "contributor_track", "contributor", $key, $to);
            _updateTable($currDbh, "library_contributor", "contributor", $key, $to);
            _updateTable($currDbh, "works", "composer", $key, $to);
            if ($haveMLibContrib) {
                _updateTable($currDbh, "multilibrary_contributor", "contributor", $key, $to);
            }
        }
    }

    if (%currAlbumIdsToPrev) {
        main::INFOLOG && $log->is_info && $log->info("Update album IDs in other tables");
        my $haveMLibAlbum = _tableExists($currDbh, "multilibrary_album");
        foreach my $key (keys %currAlbumIdsToPrev) {
            my $to = $currAlbumIdsToPrev{$key};
            _updateTable($currDbh, "tracks", "album", $key, $to);
            _updateTable($currDbh, "contributor_album", "album", $key, $to);
            _updateTable($currDbh, "library_album", "album", $key, $to);
            if ($haveMLibAlbum) {
                _updateTable($currDbh, "multilibrary_contributor", "album", $key, $to);
            }
        }
    }

    if (%currGenreIdsToPrev) {
        main::INFOLOG && $log->is_info && $log->info("Update genre IDs in other tables");
        my $haveMLibGenre = _tableExists($currDbh, "multilibrary_genre");
        foreach my $key (keys %currGenreIdsToPrev) {
            my $to = $currGenreIdsToPrev{$key};
            _updateTable($currDbh, "genre_track", "genre", $key, $to);
            _updateTable($currDbh, "library_genre", "genre", $key, $to);
            if ($haveMLibGenre) {
                _updateTable($currDbh, "multilibrary_genre", "genre", $key, $to);
            }
        }
    }

    if (%currWorkIdsToPrev) {
        main::INFOLOG && $log->is_info && $log->info("Update work IDs in other tables");
        foreach my $key (keys %currWorkIdsToPrev) {
            my $to = $currWorkIdsToPrev{$key};
            _updateTable($currDbh, "tracks", "work", $key, $to);
        }
    }

    #
    # Update sqlite_sequence
    #

    main::INFOLOG && $log->is_info && $log->info("Update sqlite_sequence");
    if (%currTrackIdsToPrev) {
        _updateSequence($currDbh, "tracks");
    }
    if (%currContribIdsToPrev) {
        _updateSequence($currDbh, "contributors");
    }
    if (%currAlbumIdsToPrev) {
        _updateSequence($currDbh, "albums");
    }
    if (%currGenreIdsToPrev) {
        _updateSequence($currDbh, "genres");
    }
    if (%currWorkIdsToPrev) {
        _updateSequence($currDbh, "works");
    }
    if (%currPlaylistTrackIdsToPrev) {
        _updateSequence($currDbh, "playlist_track");
    }
    if (%currCommentIdsToPrev) {
        _updateSequence($currDbh, "comments");
    }

    # 
    # Check for foreight key violations...
    #

    $currDbh->do('PRAGMA foreign_keys = ON');

    $sql = $currDbh->prepare("PRAGMA foreign_key_check");
    $sql->execute();
    my $foundError = 0;

    while (my @row = $sql->fetchrow_array) {
        my ($table, $rowid, $parent, $fkid) = @row;
        $log->is_error && $log->error("Forein keys failure, Table '$table', RowID '$rowid' references missing parent '$parent' (Foreign key ID: $fkid)");
        $foundError = 1;
    }
    $sql->finish();

    #
    # DONE
    #

    if ($foundError) {
        main::INFOLOG && $log->is_info && $log->info("Rolling back changes");
        $currDbh->rollback();
    } else {
        main::INFOLOG && $log->is_info && $log->info("Commiting changes");
        $currDbh->commit();
    }
}

1;
