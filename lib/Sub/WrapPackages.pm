use strict;
use warnings;

package Sub::WrapPackages;

use vars qw($VERSION %ORIGINAL_SUBS);

$VERSION = '2.0';

%ORIGINAL_SUBS = ();

=head1 NAME

Sub::WrapPackages - add pre- and post-execution wrappers around all the
subroutines in packages or around individual subs

=head1 SYNOPSIS

    use Sub::WrapPackages
        packages => [qw(Foo Bar Baz::*)],   # wrap all subs in Foo and Bar
                                            #   and any Baz::* packages
        subs     => [qw(Barf::a, Barf::b)], # wrap these two subs as well
        wrap_inherited => 1,                # and wrap any methods
                                            #   inherited by Foo, Bar, or
                                            #   Baz::*
        pre      => sub {
            print "called $_[0] with params ".
              join(', ', @_[1..$#_])."\n";
        },
        post     => sub {
            print "$_[0] returned $_[1]\n";
        };

=head1 COMPATIBILITY

While this module does broadly the same job as the 1.x versions did,
the interface may have changed incompatibly.  Sorry.  Hopefully it'll
be more maintainable and less crazily magical.

=head1 DESCRIPTION

This module installs pre- and post- execution subroutines for the
subroutines you specify.  The pre-execution subroutine is passed the
wrapped subroutine's name and all its arguments.  The post-execution
subroutine is passed the wrapped sub's name and its results.

The return values from the pre- and post- subs are ignored, and they
are called in the same context (void, scalar or list) as the calling
code asked for.

Normal usage is to pass a bunch of parameters when the module is used.
However, you can also call Sub::WrapPackages::wrapsubs with the same
parameters.

=head1 CAVEATS

C<caller> breaks badly.

=head1 PARAMETERS

=over 4

=item the subs arrayref

In the synopsis above, you will see two named parameters, C<subs> and
C<packages>.  Any subroutine mentioned in C<subs> will be wrapped.
Any subroutines mentioned in 'subs' must already exist - ie their modules
must be loaded - at the time you try to wrap them.

=items the packages arrayref

Any package mentioned here will have all its subroutines wrapped,
including any that it imports at load-time.  Packages can be loaded
in any order - they don't have to already be loaded for Sub::WrapPackages
to work its magic.  However, if after loading Sub::WrapPackages you
mess around with @INC - eg with a late C<use lib> - all bets are off.

You can specify wildcard packages.  Anything ending in ::* is assumed
to be such.  For example, if you specify Orchard::Tree::*, then that
matches Orchard::Tree, Orchard::Tree::Pear, Orchard::Apple::KingstonBlack
etc, but not - of course - Pine::Tree or My::Orchard::Tree.

Note, however, that if a module exports a subroutine at load-time using
C<import> then that sub will be wrapped in the exporting module but not in
the importing module.  This is because import() runs before we get a chance
to fiddle with things.  Sorry.

=item wrap_inherited

In conjunction with the C<packages> arrayref, this wraps all calls to
inherited methods made through those packages.  If you call those
methods directly in the superclass then they are not affected - unless
they're wrapped in the superclass of course.

=back

=head1 BUGS

Wrapped subroutines may cause perl 5.6.1, and maybe other versions, to
segfault when called in void context.  At least, they did back when
this was a thin layer around Hook::LexWrap.

AUTOLOAD and DESTROY are not treated as being special.

=head1 FEEDBACK

I like to know who's using my code.  All comments, including constructive
criticism, are welcome.  Please email me.

=head1 SOURCE CODE REPOSITORY

L<http://www.cantrell.org.uk/cgit/cgit.cgi/perlmodules/>

=head1 COPYRIGHT and LICENCE

Copyright 2003-2009 David Cantrell E<lt>F<david@cantrell.org.uk>E<gt>

This software is free-as-in-speech software, and may be used, distributed, and modified under the terms of either the GNU General Public Licence version 2 or the Artistic Licence. It's up to you which one you use. The full text of the licences can be found in the files GPL2.txt and ARTISTIC.txt, respectively.

=head1 THANKS TO

Thanks also to Adam Trickett who thought this was a jolly good idea,
Tom Hukins who prompted me to add support for inherited methods, and Ed
Summers, whose code for figgering out what functions a package contains
I borrowed out of L<Acme::Voodoo>.

Thanks to Tom Hukins for sending in a test case for the situation when
a class and a subclass are both defined in the same file.

Thanks to Dagfinn Ilmari Mannsaker for help with the craziness for
fiddling with modules that haven't yet been loaded.

=cut

sub import {
    shift;
    wrapsubs(@_) if(@_);
}

sub _subs_in_packages {
    my @targets = map { $_.'::' } @_;

    my @subs;
    foreach my $package (@targets) {
        no strict;
        while(my($k, $v) = each(%{$package})) {
            push @subs, $package.$k if(defined(&{$v}));
        }
    }
    return @subs;
}

sub _make_magic_inc {
    my %params = @_;
    my $wildcard_packages = [map { s/::.//; $_; } grep { /::\*$/ } @{$params{packages}}];
    my $nonwildcard_packages = [grep { $_ !~ /::\*$/ } @{$params{packages}}];

    unshift @INC, sub {
        my($me, $file) = @_;
        (my $module = $file) =~ s{/}{::}g;
        $module =~ s/\.pm//;
        return undef unless(
            (grep { $module =~ /^$_(::|$)/ } @{$wildcard_packages}) ||
            (grep { $module eq $_ } @{$nonwildcard_packages})
        );
        local @INC = grep { $_ ne $me } @INC;
        local $/;
        my @files = grep { -e $_ } map { join('/', $_, $file) } @INC;
        open(my $fh, $files[0]) || die("Can't locate $file in \@INC\n");
        my $text = <$fh>;
        close($fh);
        %Sub::WrapPackages::params = %params;

        $text =~ /(.*?)(__DATA__|__END__|$)/s;
        my($code, $trailer) = ($1, $2);
        $text = $code.qq[
            ;
            Sub::WrapPackages::wrapsubs(
                %Sub::WrapPackages::params,
                packages => [qw($module)]
            );
            1;
        ].$trailer;
        open($fh, '<', \$text);
        $fh;
    };
}

sub wrapsubs {
    my %params = @_;

    if(exists($params{packages}) && ref($params{packages}) =~ /^ARRAY/) {
        my $wildcard_packages = [map { (my $foo = $_) =~ s/::.$//; $foo; } grep { /::\*$/ } @{$params{packages}}];
        my $nonwildcard_packages = [grep { $_ !~ /::\*$/ } @{$params{packages}}];

        # wrap stuff that's not yet loaded
        _make_magic_inc(%params);

        # wrap wildcards that *are* loaded
        if(@{$wildcard_packages}) {
            foreach my $loaded (map { (my $f = $_) =~ s!/!::!g; $f =~ s/\.pm$//; $f } keys %INC) {
                my $pattern = '^('.join('|',
                    map { (my $f = $_) =~ s/::\*$/::/; $f } @{$wildcard_packages}
                ).')';
                wrapsubs(%params, packages => [$loaded]) if($loaded =~ /$pattern/);
            }
        }

        # wrap non-wildcards that *are* loaded
        if($params{wrap_inherited}) {
            foreach my $package (@{$nonwildcard_packages}) {
                # FIXME? does this work with 'use base'
                my @parents = eval '@'.$package.'::ISA';

                # get inherited (but not over-ridden!) subs
                my %subs_in_package = map {
                    s/.*:://; ($_, 1);
                } _subs_in_packages($package);

                my @subs_to_define = grep {
                    !exists($subs_in_package{$_})
                } map { 
                    s/.*:://; $_;
                } _subs_in_packages(@parents);

                # define them in $package using SUPER
                foreach my $sub (@subs_to_define) {
                    no strict;
                    *{$package."::$sub"} = eval "
                        sub {
                            package $package;
                            my \$self = shift;
                            \$self->SUPER::$sub(\@_);
                        };
                    ";
                    eval 'package __PACKAGE__';
                    # push @{$params{subs}}, $package."::$sub";
                }
            }
        }
        push @{$params{subs}}, _subs_in_packages(@{$params{packages}});
    } elsif(exists($params{packages})) {
        die("Bad param 'packages'");
    }

    return undef if(!$params{pre} && !$params{post});

    foreach my $sub (@{$params{subs}}) {
        next if(exists($ORIGINAL_SUBS{$sub}));

        $ORIGINAL_SUBS{$sub} = \&{$sub};
        my $imposter = sub {
            my(@r, $r) = ();
            my $wa = wantarray();
            if(!defined($wa)) {
                $params{pre}->($sub, @_);
                $ORIGINAL_SUBS{$sub}->(@_);
                $params{post}->($sub);
            } elsif($wa) {
                 my @f = $params{pre}->($sub, @_);
                 @r = $ORIGINAL_SUBS{$sub}->(@_);
                 @f = $params{post}->($sub, @r);
            } else {
                 my $f = $params{pre}->($sub, @_);
                 $r = $ORIGINAL_SUBS{$sub}->(@_);
                 $f = $params{post}->($sub, $r);
            }
            return wantarray() ? @r : $r;
        };
        {
            no strict 'refs';
            no warnings 'redefine';
            *{$sub} = $imposter;
        };
    }
}

1;
