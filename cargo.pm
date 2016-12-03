# debhelper buildsystem for Rust crates using Cargo
#
# Josh Triplett <josh@joshtriplett.org>

package Debian::Debhelper::Buildsystem::cargo;

use strict;
use warnings;
use Cwd;
use Debian::Debhelper::Dh_Lib;
use Dpkg::Changelog::Debian;
use Dpkg::Control::Info;
use Dpkg::Version;
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

    $this->{cargo_home} = Cwd::abs_path($this->get_sourcepath("debian/cargo_home"));
    $this->{cargo_registry} = Cwd::abs_path($this->get_sourcepath("debian/cargo_registry"));

    my $control = Dpkg::Control::Info->new();

    my $source = $control->get_source();
    my $crate = $source->{'X-Cargo-Crate'};
    if (!$crate) {
        $crate = $source->{Source};
        $crate =~ s/^rust-//;
    }
    $this->{crate} = $crate;
    my $changelog = Dpkg::Changelog::Debian->new(range => { count => 1 });
    $changelog->load($this->get_sourcepath("debian/changelog"));
    $this->{version} = Dpkg::Version->new(@{$changelog}[0]->get_version())->version();

    my @packages = $control->get_packages();
    $this->{libpkg} = 0;
    $this->{binpkg} = 0;
    $this->{featurepkg} = [];
    foreach my $package (@packages) {
        if ($package->{Package} =~ /^librust-.*-dev$/ && $package->{Architecture} eq 'all') {
            if ($package->{Package} =~ /\+/) {
                push(@{$this->{featurepkg}}, $package->{Package});
                next;
            }
            if ($this->{libpkg}) {
                error("Multiple Cargo lib packages found: " . $this->{libpkg} . " and " . $package->{Package});
            }
            $this->{libpkg} = $package->{Package};
        } elsif ($package->{Architecture} ne 'all') {
            $this->{binpkg} = $package->{Package};
        }
    }
    if (!$this->{libpkg} && !$this->{binpkg}) {
        error("Could not find any Cargo lib or bin packages to build.");
    }
    if (@{$this->{featurepkg}} && !$this->{libpkg}) {
        error("Found feature packages but no lib package.");
    }

    my $parallel = $this->get_parallel();
    $this->{j} = $parallel > 0 ? ["-j$parallel"] : [];

    $this->SUPER::pre_building_step($step);
}

sub get_sources {
    my $this=shift;
    opendir(my $dirhandle, $this->get_sourcedir());
    my @sources = grep { $_ ne '.' && $_ ne '..' && $_ ne '.git' && $_ ne 'debian' } readdir($dirhandle);
    closedir($dirhandle);
    @sources
}

sub configure {
    my $this=shift;
}

sub install {
    my $this=shift;
    my $crate = $this->{crate} . '-' . $this->{version};
    if ($this->{libpkg}) {
        my $target = $this->get_sourcepath("debian/" . $this->{libpkg} . "/usr/share/cargo/registry/$crate");
        my @sources = $this->get_sources();
        doit("mkdir", "-p", $target);
        doit("cp", "-at", $target, @sources);
        doit("cp", $this->get_sourcepath("debian/cargo-checksum.json"), "$target/.cargo-checksum.json");
    }
    foreach my $pkg (@{$this->{featurepkg}}) {
        my $target = $this->get_sourcepath("debian/$pkg/usr/share/doc");
        doit("mkdir", "-p", $target);
        doit("ln", "-s", $this->{libpkg}, "$target/$pkg");
    }
    if ($this->{binpkg}) {
        my $registry = $this->{cargo_registry};
        doit("mkdir", "-p", $this->{cargo_home}, $registry);
        opendir(my $dirhandle, '/usr/share/cargo/registry');
        my @crates = map { "/usr/share/cargo/registry/$_" } grep { $_ ne '.' && $_ ne '..' } readdir($dirhandle);
        closedir($dirhandle);
        if (@crates) {
            doit("ln", "-st", "$registry", @crates);
        }
        # Handle the case of building the package with the same version of the
        # package installed.
        if (-l "$registry/$crate") {
            unlink("$registry/$crate");
        }
        mkdir("$registry/$crate");
        my @sources = $this->get_sources();
        doit("cp", "-at", "$registry/$crate", @sources);
        doit("cp", $this->get_sourcepath("debian/cargo-checksum.json"), "$registry/$crate/.cargo-checksum.json");

        open(CONFIG, ">" . $this->{cargo_home} . "/config");
        print(CONFIG qq{
[source.crates-io]
replace-with = "dh-cargo-registry"

[source.dh-cargo-registry]
directory = "$registry"
});
        close(CONFIG);
        $ENV{'CARGO_HOME'} = $this->{cargo_home};

        my $target = $this->get_sourcepath("debian/" . $this->{binpkg} . "/usr");
        doit("cargo", "install", $this->{crate}, "--vers", $this->{version}, "--root", $target, @{$this->{j}});
        doit("rm", "$target/.crates.toml");
    }
}

sub clean {
    my $this=shift;
    doit("rm", "-rf", $this->{cargo_home}, $this->{cargo_registry});
}

1
