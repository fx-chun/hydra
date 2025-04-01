package Hydra::Plugin::GiteaRefs;

use strict;
use warnings;
use parent 'Hydra::Plugin';
use HTTP::Request;
use LWP::UserAgent;
use JSON::MaybeXS;
use Hydra::Helper::CatalystUtils;
use File::Temp;
use POSIX qw(strftime);

=head1 NAME

GiteaRefs - Hydra plugin for retrieving the list of references (branches or
tags) from Gitea following a certain naming scheme

=head1 DESCRIPTION

This plugin reads the list of branches or tags using Gitea's REST API. The name
of the reference must follow a particular prefix. This list is stored in the
nix-store and used as an input to declarative jobsets.

=head1 CONFIGURATION

The plugin doesn't require any dedicated configuration block, but it has to
consult C<gitea_authorization> entry for obtaining the API token. In addition,

The declarative project C<spec.json> file must contains an input such as

   "pulls": {
     "type": "gitea_refs",
     "value": "[gitea_hostname] [owner] [repo] heads|tags [scheme] - [prefix]",
     "emailresponsible": false
   }

In the above snippet, C<[gitea_hostname]> must be set to the hostname of the
repository's Gitea instance.

C<[owner]> is the repository owner and C<[repo]> is the repository name. Also
note a literal C<->, which is placed there for the future use.

C<heads|tags> denotes that one of these two is allowed, that is, the third
position should hold either the C<heads> or the C<tags> keyword. In case of the former, the plugin
will fetch all branches, while in case of the latter, it will fetch the tags.

C<scheme> should be set to either https or http, depending on what the Gitea
host supports.

C<prefix> denotes the prefix the reference name must start with, in order to be
included.

For example, C<"value": "projects.blender.org blender blender heads https - blender-v/"> refers to
L<https://projects.blender.org/blender/blender> repository, and will fetch all branches that
begin with C<blender-v/>.

=head1 USE

The result is stored in the nix-store as a JSON I<map>, where the key is the
name of the reference, while the value is the complete Gitea response. Thus,
any of the values listed in
L<https://docs.gitea.com/api#tag/repository/operation/repoListAllGitRefs> can be
used to build the git input value in C<jobsets.nix>.

=cut

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'gitea_refs'} = 'Open Gitea Refs';
}

sub _iterate {
    my ($url, $auth, $refs, $ua) = @_;
    my $req = HTTP::Request->new('GET', $url);
    $req->header('Accept' => 'application/json');
    $req->header('Authorization' => $auth) if defined $auth;
    my $res = $ua->request($req);
    my $content = $res->decoded_content;
    die "Error pulling from the gitea refs API: $content\n"
        unless $res->is_success;
    my $refs_list = decode_json $content;
    # TODO Stream out the json instead
    foreach my $ref (@$refs_list) {
        my $ref_name = $ref->{ref};
        $ref_name =~ s,^refs/(?:heads|tags)/,,o;
        $refs->{$ref_name} = $ref;
    }
    # TODO Make Link header parsing more robust!!!
    my @links = split ',', $res->header("Link");
    my $next = "";
    foreach my $link (@links) {
        my ($url, $rel) = split ";", $link;
        if (trim($rel) eq 'rel="next"') {
            $next = substr trim($url), 1, -1;
            last;
        }
    }
    _iterate($next, $auth, $refs, $ua) unless $next eq "";
}

sub fetchInput {
    my ($self, $input_type, $name, $value, $project, $jobset) = @_;
    return undef if $input_type ne "gitea_refs";

    my ($giteaHostname, $owner, $repo, $type, $scheme, $fut, $prefix) = split ' ', $value;
    die "type field is neither 'heads' nor 'tags', but '$type'"
        unless $type eq 'heads' or $type eq 'tags';
    die "scheme field is neither 'https' nor 'http' but '$scheme'"
        unless $scheme eq 'https' or $scheme eq 'http';

    my $auth = $self->{config}->{gitea_authorization}->{$owner};
    my $giteaEndpoint = "$scheme://$giteaHostname";
    my %refs;
    my $ua = LWP::UserAgent->new();
    _iterate("$giteaEndpoint/api/v1/repos/$owner/$repo/git/refs/$type/$prefix?per_page=100", $auth, \%refs, $ua);
    my $tempdir = File::Temp->newdir("gitea-refs" . "XXXXX", TMPDIR => 1);
    my $filename = "$tempdir/gitea-refs.json";
    open(my $fh, ">", $filename) or die "Cannot open $filename for writing: $!";
    print $fh encode_json \%refs;
    close $fh;
    system("jq -S . < $filename > $tempdir/gitea-refs-sorted.json");
    my $storePath = trim(qx{nix-store --add "$tempdir/gitea-refs-sorted.json"}
        or die "cannot copy path $filename to the Nix store.\n");
    chomp $storePath;
    my $timestamp = time;
    return { storePath => $storePath, revision => strftime "%Y%m%d%H%M%S", gmtime($timestamp) };
}

1;
