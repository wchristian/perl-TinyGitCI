package TinyGitCI::Repo;

use Mu;
use strictures 2;
use experimental 'signatures';

# ABSTRACT: stores the metadata for a repo in TinyGitCI

# VERSION

around BUILDARGS => sub ( $orig, $class, @args )    #
{ ( @args == 1 and ref $args[0] ne "HASH" ) ? { path => $args[0] } : $class->$orig(@args) };

ro "path";
ro remote => default => "origin";

1;
