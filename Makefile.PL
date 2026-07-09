use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'MongrelDB',
    AUTHOR        => 'Visorcraft <noreply@visorcraft.com>',
    VERSION_FROM  => 'lib/MongrelDB.pm',
    ABSTRACT_FROM => 'lib/MongrelDB.pm',
    LICENSE       => 'open_source',
    META_MERGE    => {
        'meta-spec' => { version => 2 },
        resources   => {
            homepage   => 'https://www.mongreldb.com',
            repository => {
                type => 'git',
                url  => 'https://github.com/visorcraft/MongrelDB-Perl.git',
                web  => 'https://github.com/visorcraft/MongrelDB-Perl',
            },
            bugtracker => {
                web => 'https://github.com/visorcraft/MongrelDB-Perl/issues',
            },
        },
        keywords => [qw(database sql embedded-database mongreldb perl)],
    },
    PREREQ_PM => {
        # Both have shipped with Perl core since 5.14.
        'HTTP::Tiny' => 0,
        'JSON::PP'   => 0,
    },
    BUILD_REQUIRES => {
        'Test::More' => 0,
    },
    test => { TESTS => 't/*.t' },
);
