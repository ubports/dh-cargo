# debhelper buildsystem for Rust crates using Cargo
#
# Josh Triplett <josh@joshtriplett.org>

package Debian::Debhelper::Buildsystem::cargo;

use strict;
use warnings;
use Debian::Debhelper::Dh_Lib qw(doit error);
use Dpkg::Control::Info;
use base 'Debian::Debhelper::Buildsystem';

sub DESCRIPTION {
    "Rust Cargo"
}

sub check_auto_buildable {
    my $this = shift;
    if (-f $this->get_sourcepath("Cargo.toml")) {
        return 1;
    }
    return 0;
}

sub new {
    my $class = shift;
    my $this = $class->SUPER::new(@_);
    $this->enforce_in_source_building();
    return $this;
}

sub pre_building_step {
    my $this = shift;
    my $step = shift;

    $this->{cargo_home} = $this->get_buildpath("debian/cargo_home");
    $ENV{'CARGO_HOME'} = $this->{cargo_home};

    my $control = Dpkg::Control::Info->new();
    my @packages = $control->get_packages();
    $this->{libpkg} = 0;
    $this->{binpkg} = 0;
    foreach my $package (@packages) {
        if ($package->{Package} =~ /^librust-.*-dev$/ && $package->{Architecture} eq 'all') {
            $this->{libpkg} = $package->{Package};
        } elsif ($package->{Architecture} ne 'all') {
            $this->{binpkg} = $package->{Package};
        }
    }
    if (!$this->{libpkg} && !$this->{binpkg}) {
        error("Could not find any Cargo lib or bin packages to build.");
    }

    my $parallel = $this->get_parallel();
    $this->{j} = $parallel > 0 ? ["-j$parallel"] : [];

    $this->SUPER::pre_building_step($step);
}

sub configure {
    my $this=shift;
    doit("mkdir", "-p", $this->{cargo_home});
    doit("cp", "/usr/share/cargo/config", $this->{cargo_home});
}

sub build {
    my $this=shift;
    if ($this->{libpkg}) {
        # Could skip this and copy the files directly in install if "cargo
        # package --list0" existed.  See
        # https://github.com/rust-lang/cargo/issues/3306
        doit("cargo", "package", "--no-verify");
    }
    if ($this->{binpkg}) {
        doit("cargo", "build", "--release", @{$this->{j}});
    }
}

sub install {
    my $this=shift;
    if ($this->{libpkg}) {
        my $target = $this->get_sourcepath("debian/" . $this->{libpkg} . "/usr/share/cargo/registry/");
        my $pkgdir = $this->get_sourcepath("target/package");
        opendir(my $dh, $pkgdir);
        my @crates = grep(/\.crate$/, readdir($dh));
        closedir($dh);
        if (@crates != 1) {
            error("Could not find unique .crate file in $pkgdir");
        }
        my $crate_name = $crates[0];
        my $crate = "$pkgdir/$crate_name";
        $crate_name =~ s/\.crate$//;
        doit("mkdir", "-p", $target);
        doit("tar", "-C", $target, "-x", "--anchored", "--no-wildcards-match-slash", "--exclude=*/debian", "-f", $crate);
        doit("cp", $this->get_sourcepath("debian/cargo-checksum.json"), "$target/$crate_name/.cargo-checksum.json");
    }
    if ($this->{binpkg}) {
        my $target = $this->get_sourcepath("debian/" . $this->{binpkg} . "/usr");
        doit("cargo", "install", "--root", $target);
        doit("rm", "$target/.crates.toml");
    }
}

sub test {
    my $this=shift;
    doit("cargo", "test", "--release", @{$this->{j}});
}

sub clean {
    my $this=shift;
    doit("cargo", "clean");
    doit("rm", "-rf", $this->{cargo_home});
    # For now, always delete Cargo.lock, since the upstream crates never
    # include it. This may need to change if future crates start including it.
    # See https://github.com/rust-lang/cargo/issues/2263
    doit("rm", "-f", $this->get_sourcepath('Cargo.lock'));
}

1
