package App::ModuleBuildTiny;

use 5.014;
use strict;
use warnings;
our $VERSION = '0.035';

use Exporter 5.57 'import';
our @EXPORT = qw/modulebuildtiny/;

use Config;
use CPAN::Meta;
use Data::Section::Simple 'get_data_section';
use Encode qw/encode_utf8 decode_utf8/;
use ExtUtils::Manifest qw/manifind maniskip maniread/;
use File::Basename qw/dirname/;
use File::Path qw/mkpath/;
use File::Slurper qw/write_text write_binary read_binary/;
use File::Spec::Functions qw/catfile catdir curdir rel2abs/;
use Getopt::Long 2.36 'GetOptionsFromArray';
use JSON::PP qw/decode_json/;
use Module::Runtime 'require_module';
use Pod::Simple::Text 3.23;
use Text::Template;

use App::ModuleBuildTiny::Dist;

use Env qw/$AUTHOR_TESTING $RELEASE_TESTING $AUTOMATED_TESTING $EXTENDED_TESTING $NONINTERACTIVE_TESTING $SHELL $HOME $USERPROFILE/;

Getopt::Long::Configure(qw/require_order gnu_compat/);

sub prompt {
	my($mess, $def) = @_;

	my $dispdef = defined $def ? " [$def]" : "";

	local $|=1;
	local $\;
	print "$mess$dispdef ";

	my $ans = <STDIN> // '';
	chomp $ans;
	return $ans ne '' ? decode_utf8($ans) : $def // '';
}

sub prompt_yn {
	my ($description, $default) = @_;
	my $result;
	do {
		$result = prompt("$description [y/n]", $default ? 'y' : 'n');
	} while (length $result and $result !~ /^(y|n|-)/i);
	return lc(substr $result, 0 , 1) eq 'y';
}

sub create_license_for {
	my ($license_name, $author) = @_;
	my $module = "Software::License::$license_name";
	require_module($module);
	return $module->new({ holder => $author });
}

sub fill_in {
	my ($template, $hash) = @_;
	return Text::Template->new(TYPE => 'STRING', SOURCE => $template)->fill_in(HASH => $hash);
}

sub write_module {
	my %opts = @_;
	my $template = get_data_section('Module.pm') =~ s/ ^ % (\w+) /=$1/gxmsr;
	my $filename = catfile('lib', split /::/, $opts{module_name}) . '.pm';
	my $content = fill_in($template, \%opts);
	mkpath(dirname($filename));
	write_text($filename, $content);
}

sub write_changes {
	my %opts = @_;
	my $template = get_data_section('Changes');
	my $content = fill_in($template, \%opts);
	write_text('Changes', $content);
}

sub write_maniskip {
	my $distname = shift;
	write_text('MANIFEST.SKIP', "#!include_default\n$distname-.*\nREADME.pod\n");
	maniskip(); # This expands the #!include_default as a side-effect
	unlink 'MANIFEST.SKIP.bak' if -f 'MANIFEST.SKIP.bak';
}

sub write_readme {
	my %opts = @_;
	my $template = get_data_section('README');
	write_text('README', fill_in($template, \%opts));
}

sub get_config_file {
	local $HOME = $USERPROFILE if $^O eq 'MSWin32';
	return catfile(glob('~'), qw/.mbtiny conf/);
}

sub read_json {
	my $filename = shift;
	-f $filename or return;
	return decode_json(read_binary($filename));
}

sub write_json {
	my ($filename, $content) = @_;
	my $dirname = dirname($filename);
	mkdir $dirname if not -d $dirname;
	my $json = JSON::PP->new->utf8->pretty->canonical->encode($content);
	return write_binary($filename, $json);
}

sub bump_versions {
	my (%opts) = @_;
	require App::RewriteVersion;
	my $app = App::RewriteVersion->new(%opts);
	my $trial = delete $opts{trial};
	my $new_version = defined $opts{version} ? delete $opts{version} : $app->bump_version($app->current_version);
	$app->rewrite_versions($new_version, is_trial => $trial);
}

my %prompt_for = (
	open => \&prompt,
	yn => \&prompt_yn,
);

my @config_items = (
	[ 'author'   , 'What is the author\'s name?', 'open' ],
	[ 'email'    , 'What is the author\'s email?', 'open',  ],
	[ 'license'  , 'What license do you want to use?', 'open', 'Perl_5' ],
	[ 'auto_git' , 'Do you want mbtiny to automatically handle git for you?', 'yn', !!1 ],
	[ 'auto_scan', 'Do you want mbtiny to automatically scan dependencies for you?', 'yn', !!1 ],
);

my %actions = (
	dist => sub {
		my @arguments = @_;
		GetOptionsFromArray(\@arguments, \my %opts, qw/trial verbose!/) or return 2;
		my $dist = App::ModuleBuildTiny::Dist->new(%opts);
		die "Trial mismatch" if $opts{trial} && $dist->release_status ne 'testing';
		$dist->check_changes;
		$dist->check_meta;
		my $name = $dist->meta->name . '-' . $dist->meta->version;
		printf "tar czf $name.tar.gz %s\n", join ' ', $dist->files if $opts{verbose};
		$dist->write_tarball($name);
		return 0;
	},
	distdir => sub {
		my @arguments = @_;
		GetOptionsFromArray(\@arguments, \my %opts, qw/trial verbose!/) or return 2;
		my $dist = App::ModuleBuildTiny::Dist->new(%opts);
		die "Trial mismatch" if $opts{trial} && $dist->release_status ne 'testing';
		$dist->write_dir($dist->meta->name . '-' . $dist->meta->version, $opts{verbose});
		return 0;
	},
	test => sub {
		my @arguments = @_;
		$AUTHOR_TESTING = 1;
		GetOptionsFromArray(\@arguments, 'release!' => \$RELEASE_TESTING, 'author!' => \$AUTHOR_TESTING, 'automated!' => \$AUTOMATED_TESTING,
			'extended!' => \$EXTENDED_TESTING, 'non-interactive!' => \$NONINTERACTIVE_TESTING) or return 2;
		my @dirs = 't';
		if ($AUTHOR_TESTING) {
			push @dirs, catdir('xt', 'author');
			push @dirs, glob 'xt/*.t';
		}
		push @dirs, catdir('xt', 'release') if $RELEASE_TESTING;
		push @dirs, catdir('xt', 'extended') if $EXTENDED_TESTING;
		@dirs = grep -e, @dirs;
		my $dist = App::ModuleBuildTiny::Dist->new;
		return $dist->run(command => [ 'prove', '-br', @dirs ], build => 1, verbose => 1);
	},
	upload => sub {
		my @arguments = @_;
		my $config_file = get_config_file();
		my $config = -f $config_file ? read_json($config_file) : {};
		my %opts = $config->{auto_git} ? (tag => 1, push => '') : ();
		GetOptionsFromArray(\@arguments, \%opts, qw/trial config=s silent tag! push:s nopush|no-push/) or return 2;

		my $dist = App::ModuleBuildTiny::Dist->new;
		$dist->check_changes;
		$dist->check_meta;
		local ($AUTHOR_TESTING, $RELEASE_TESTING) = (1, 1);
		$dist->run(command => [ catfile(curdir, 'Build'), 'test' ], build => 1, verbose => !$opts{silent}) or return 1;

		my $sure = prompt_yn('Do you want to continue the release process?', 'n');
		if ($sure) {
			my $trial =  $dist->release_status eq 'testing' && $dist->version !~ /_/;
			my $name = $dist->meta->name . '-' . $dist->meta->version . ($trial ? '-TRIAL' : '' );
			my $file = $dist->write_tarball($name);
			require CPAN::Upload::Tiny;
			CPAN::Upload::Tiny->VERSION('0.009');
			my $uploader = CPAN::Upload::Tiny->new_from_config_or_stdin($opts{config});
			$uploader->upload_file($file);
			print "Successfully uploaded $file\n" if not $opts{silent};

			if ($opts{tag}) {
				require Git::Wrapper;
				my $git = Git::Wrapper->new('.');
				my $version = 'v' . $dist->version;
				$git->tag('-m' => $version, $version);
			}

			if (defined $opts{push} and not $opts{nopush}) {
				require Git::Wrapper;
				my $git = Git::Wrapper->new('.');

				my @remote = length $opts{push} ? $opts{push} : ();
				$git->push(@remote);
				$git->push({ tags => 1 }, @remote) if $opts{tag};
			}
		}
		return 0;
	},
	run => sub {
		my @arguments = @_;
		die "No arguments given to run\n" if not @arguments;
		GetOptionsFromArray(\@arguments, 'build!' => \(my $build = 1)) or return 2;
		my $dist = App::ModuleBuildTiny::Dist->new();
		return $dist->run(command => \@arguments, build => $build, verbose => 1);
	},
	shell => sub {
		my @arguments = @_;
		GetOptionsFromArray(\@arguments, 'build!' => \my $build) or return 2;
		my $dist = App::ModuleBuildTiny::Dist->new();
		return $dist->run(command => [ $SHELL ], build => $build, verbose => 0);
	},
	listdeps => sub {
		my @arguments = @_;
		GetOptionsFromArray(\@arguments, \my %opts, qw/json only_missing|only-missing|missing omit_core|omit-core=s author versions/) or return 2;
		my $dist = App::ModuleBuildTiny::Dist->new;

		require CPAN::Meta::Prereqs::Filter;
		my $prereqs = CPAN::Meta::Prereqs::Filter::filter_prereqs($dist->meta->effective_prereqs, %opts);

		if (!$opts{json}) {
			my @phases = qw/build test configure runtime/;
			push @phases, 'develop' if $opts{author};

			my $reqs = $prereqs->merged_requirements(\@phases);
			$reqs->clear_requirement('perl');

			my @modules = sort { lc $a cmp lc $b } $reqs->required_modules;
			if ($opts{versions}) {
				say "$_ = ", $reqs->requirements_for_module($_) for @modules;
			}
			else {
				say for @modules;
			}
		}
		else {
			require JSON::PP;
			print JSON::PP->new->ascii->canonical->pretty->encode($prereqs->as_string_hash);
		}
		return 0;
	},
	regenerate => sub {
		my @arguments = @_;
		my $config_file = get_config_file();
		my $config = -f $config_file ? read_json($config_file) : {};
		my %opts = (scan => $config->{auto_scan});
		GetOptionsFromArray(\@arguments, \%opts, qw/trial bump version=s verbose dry_run|dry-run commit! scan!/) or return 2;
		$opts{commit} //= $opts{bump} if $config->{auto_git};
		my %files = map { $_ => 1 } @arguments ? @arguments : qw/Build.PL META.json META.yml MANIFEST LICENSE README/;

		if ($opts{scan}) {
			my $dist = App::ModuleBuildTiny::Dist->new(regenerate => { 'META.json' => 1 });
			my $prereqs = $dist->scan_prereqs(%opts, sanitize => 1);
			write_json('prereqs.json', $prereqs->as_string_hash) if !$opts{dry_run};
		}

		if ($opts{bump}) {
			bump_versions(%opts);
			$files{Changes}++;
		}

		my $dist = App::ModuleBuildTiny::Dist->new(%opts, regenerate => \%files);
		my @generated = grep { $files{$_} } $dist->files;
		for my $filename (@generated) {
			say "Updating $filename" if $opts{verbose};
			write_binary($filename, $dist->get_file($filename)) if !$opts{dry_run};
		}

		if ($opts{commit}) {
			require Git::Wrapper;
			my $git = Git::Wrapper->new('.');
			my @files = keys %files;
			if ($opts{bump}) {
				push @files, 'lib';
				push @files, 'script' if -d 'script';
			}
			my $allowed = join '|', map qr{^\Q$_\E$}, @files;
			my @modified = grep /$allowed/, $git->ls_files({ modified => 1 });

			if (@modified) {
				my @changes = $dist->get_changes;
				my $version = 'v' . $dist->version;
				my $message = join '', $version, "\n\n", @changes;
				$git->commit({ m => $message }, @files);
			} else {
				say "No modifications to commit";
			}
		}
		return 0;
	},
	scan => sub {
		my @arguments = @_;
		my %opts = (sanitize => 1);
		GetOptionsFromArray(\@arguments, \%opts, qw/omit_core|omit-core=s sanitize! omit=s@/) or return 2;
		my $dist = App::ModuleBuildTiny::Dist->new(regenerate => { 'META.json' => 1 });
		my $prereqs = $dist->scan_prereqs(%opts);
		write_json('prereqs.json', $prereqs->as_string_hash);
		return 0;
	},
	setup => sub {
		my @arguments = @_;
		my $config_file = get_config_file();

		my $mode = @arguments ? $arguments[0] : 'upgrade';

		my $save = sub {
			my ($config, $type, $key, $value) = @_;
			if ($value ne '-') {
				$config->{$key} = $type eq 'open' ? $value : $value ? $JSON::PP::true : $JSON::PP::false;
			}
			else {
				delete $config->{$key};
			}
		};
		if ($mode eq 'upgrade') {
			my $config = -f $config_file ? read_json($config_file) : {};
			for my $item (@config_items) {
				my ($key, $description, $type, $default) = @{$item};
				next if defined $config->{$key};
				$save->($config, $type, $key, $prompt_for{$type}->($description, $default));
			}
			write_json($config_file, $config);
		}
		elsif ($mode eq 'all') {
			my $config = -f $config_file ? read_json($config_file) : {};
			for my $item (@config_items) {
				my ($key, $description, $type, $default) = @{$item};
				my $new_value = $prompt_for{$type}->($description, $config->{$key} // $default);
				$save->($config, $type, $key, $new_value);
			}
			write_json($config_file, $config);
		}
		elsif ($mode eq 'list') {
			my $config = -f $config_file ? read_json($config_file) : {};
			for my $item (@config_items) {
				my ($key, $description, $type, $default) = @{$item};
				my $value = defined $config->{$key} ? $type eq 'open' ? $config->{$key} : $config->{$key} ? 'true' : 'false' : '(undefined)';
				say "\u$key: $value";
			}
		}
		elsif ($mode eq 'reset') {
			return not unlink $config_file;
		}
		return 0;
	},
	mint => sub {
		my @arguments = @_;

		my $config_file = get_config_file();
		my $config = -f $config_file ? read_json($config_file) // {} : {};

		my $distname = decode_utf8(shift @arguments // die "No distribution name given\n");
		die "Directory $distname already exists\n" if -e $distname;

		my %args = (
			%{ $config },
			version => '0.001',
			dirname => $distname,
			abstract => 'INSERT YOUR ABSTRACT HERE',
		);
		GetOptionsFromArray(\@arguments, \%args, qw/author=s email=s license=s version=s abstract=s dirname=s/) or return 2;
		for my $item (@config_items) {
			my ($key, $description, $type, $default) = @{$item};
			next if $type ne 'open'; # may need a field of its own
			next if defined $args{$key};
			$args{$key} = prompt($description, $default);
		}

		my $license = create_license_for(delete $args{license}, $args{author});

		mkdir $args{dirname};
		chdir $args{dirname};
		$args{module_name} = $distname =~ s/-/::/gr;

		write_module(%args, notice => $license->notice);
		write_text('LICENSE', $license->fulltext);
		write_changes(%args, distname => $distname);
		write_maniskip($distname);

		return 0;
	},
);

sub modulebuildtiny {
	my ($action, @arguments) = @_;
	die "No action given\n" unless defined $action;
	my $call = $actions{$action};
	die "No such action '$action' known\n" if not $call;
	return $call->(@arguments);
}

1;

=head1 NAME

App::ModuleBuildTiny - A standalone authoring tool for Module::Build::Tiny

=head1 DESCRIPTION

App::ModuleBuildTiny contains the implementation of the L<mbtiny> tool.

=head1 FUNCTIONS

=over 4

=item * modulebuildtiny($action, @arguments)

This function runs a modulebuildtiny command. It expects at least one argument: the action. It may receive additional ARGV style options dependent on the command.

The actions are documented in the L<mbtiny> documentation.

=back

=head1 SEE ALSO

=head2 Similar programs

=over 4

=item * L<Dist::Zilla|Dist::Zilla>

An extremely powerful but somewhat heavy authoring tool.

=item * L<Minilla|Minilla>

A more minimalistic than Dist::Zilla but still somewhat customizable authoring tool.

=back

=head1 AUTHOR

Leon Timmermans <leont@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by Leon Timmermans.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

__DATA__

@@ Changes
Revision history for {{ $distname }}

{{ $version }}
          - Initial release to an unsuspecting world

@@ Module.pm
package {{ $module_name }};

use strict;
use warnings;

our $VERSION = '{{ $version }}';

1;

{{ '__END__' }}

%pod

%encoding utf-8

%head1 NAME

{{ $module_name }} - {{ $abstract }}

%head1 DESCRIPTION

Write a full description of the module and its features here.

%head1 AUTHOR

{{ $author }} <{{ $email }}>

%head1 COPYRIGHT AND LICENSE

{{ $notice }}

