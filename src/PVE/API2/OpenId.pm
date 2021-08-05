package PVE::API2::OpenId;

use strict;
use warnings;

use PVE::Tools qw(extract_param);
use PVE::RS::OpenId;

use PVE::Exception qw(raise raise_perm_exc raise_param_exc);
use PVE::SafeSyslog;
use PVE::RPCEnvironment;
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::AccessControl;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Auth::Plugin;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

my $openid_state_path = "/var/lib/pve-manager";

my $lookup_openid_auth = sub {
    my ($realm, $redirect_url) = @_;

    my $cfg = cfs_read_file('domains.cfg');
    my $ids = $cfg->{ids};

    die "authentication domain '$realm' does not exist\n" if !$ids->{$realm};

    my $config = $ids->{$realm};
    die "wrong realm type ($config->{type} != openid)\n" if $config->{type} ne "openid";

    my $openid_config = {
	issuer_url => $config->{'issuer-url'},
	client_id => $config->{'client-id'},
	client_key => $config->{'client-key'},
    };

    my $openid = PVE::RS::OpenId->discover($openid_config, $redirect_url);
    return ($config, $openid);
};

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Directory index.",
    permissions => {
	user => 'all',
    },
    parameters => {
	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {
		subdir => { type => 'string' },
	    },
	},
	links => [ { rel => 'child', href => "{subdir}" } ],
    },
    code => sub {
	my ($param) = @_;

	return [
	    { subdir => 'auth-url' },
	    { subdir => 'login' },
	];
    }});

__PACKAGE__->register_method ({
    name => 'auth_url',
    path => 'auth-url',
    method => 'POST',
    protected => 1,
    description => "Get the OpenId Authorization Url for the specified realm.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    realm => get_standard_option('realm'),
	    'redirect-url' => {
		description => "Redirection Url. The client should set this to the used server url (location.origin).",
		type => 'string',
		maxLength => 255,
	    },
	},
    },
    returns => {
	type => "string",
	description => "Redirection URL.",
    },
    permissions => { user => 'world' },
    code => sub {
	my ($param) = @_;

	my $realm = extract_param($param, 'realm');
	my $redirect_url = extract_param($param, 'redirect-url');

	my ($config, $openid) = $lookup_openid_auth->($realm, $redirect_url);
	my $url = $openid->authorize_url($openid_state_path , $realm);

	return $url;
    }});

__PACKAGE__->register_method ({
    name => 'login',
    path => 'login',
    method => 'POST',
    protected => 1,
    description => " Verify OpenID authorization code and create a ticket.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    'state' => {
		description => "OpenId state.",
		type => 'string',
		maxLength => 1024,
            },
	    code => {
		description => "OpenId authorization code.",
		type => 'string',
		maxLength => 1024,
            },
	    'redirect-url' => {
		description => "Redirection Url. The client should set this to the used server url (location.origin).",
		type => 'string',
		maxLength => 255,
	    },
	},
    },
    returns => {
	properties => {
	    username => { type => 'string' },
	    ticket => { type => 'string' },
	    CSRFPreventionToken => { type => 'string' },
	    cap => { type => 'object' },  # computed api permissions
	    clustername => { type => 'string', optional => 1 },
	},
    },
    permissions => { user => 'world' },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $res;
	eval {
	    my ($realm, $private_auth_state) = PVE::RS::OpenId::verify_public_auth_state(
		$openid_state_path, $param->{'state'});

	    my $redirect_url = extract_param($param, 'redirect-url');

	    my ($config, $openid) = $lookup_openid_auth->($realm, $redirect_url);

	    my $info = $openid->verify_authorization_code($param->{code}, $private_auth_state);
	    my $subject = $info->{'sub'};

	    die "missing openid claim 'sub'\n" if !defined($subject);

	    my $unique_name = $subject; # default
	    if (defined(my $user_attr = $config->{'username-claim'})) {
		if ($user_attr eq 'subject') {
		    $unique_name = $subject;
		} elsif ($user_attr eq 'username') {
		    my $username = $info->{'preferred_username'};
		    die "missing claim 'preferred_username'\n" if !defined($username);
		    $unique_name =  $username;
		} elsif ($user_attr eq 'email') {
		    my $email = $info->{'email'};
		    die "missing claim 'email'\n" if !defined($email);
		    $unique_name = $email;
		} else {
		    die "got unexpected value for 'username-claim': '${user_attr}'\n";
		}
	    }

	    my $username = "${unique_name}\@${realm}";

	    # first, check if $username respects our naming conventions
	    PVE::Auth::Plugin::verify_username($username);

	    if ($config->{'autocreate'} && !$rpcenv->check_user_exist($username, 1)) {
		PVE::AccessControl::lock_user_config(sub {
		    my $usercfg = cfs_read_file("user.cfg");

		    die "user '$username' already exists\n" if $usercfg->{users}->{$username};

		    my $entry = { enable => 1 };
		    if (defined(my $email = $info->{'email'})) {
			$entry->{email} = $email;
		    }
		    if (defined(my $given_name = $info->{'given_name'})) {
			$entry->{firstname} = $given_name;
		    }
		    if (defined(my $family_name = $info->{'family_name'})) {
			$entry->{lastname} = $family_name;
		    }

		    $usercfg->{users}->{$username} = $entry;

		    cfs_write_file("user.cfg", $usercfg);
		}, "autocreate openid user failed");
	    } else {
		# test if user exists and is enabled
		$rpcenv->check_user_enabled($username);
	    }
	    
	    if ($rpcenv->check_user_exist($username, 1) &&
                defined(my $groups = $info->{'groups'}) &&
                ref($info->{'roles'}) eq 'ARRAY') {

                     PVE::AccessControl::lock_user_config(sub {
                         my $usercfg = cfs_read_file("user.cfg");

                         foreach my $claimed_group (@$info->{'groups'}) {
                                my $usercfg = cfs_read_file("user.cfg");

                                if ($usercfg->{groups}->{$claimed_group}) {
                                    PVE::AccessControl::add_user_group($username, $usercfg, $claimed_group);
                                } else {
                                    warn("openid: no such group '$claimed_group'");
                                    next;
                                }
                          }

                          cfs_write_file("user.cfg", $usercfg);
                      }, "update user groups failed");
                }
            }

	    my $ticket = PVE::AccessControl::assemble_ticket($username);
	    my $csrftoken = PVE::AccessControl::assemble_csrf_prevention_token($username);
	    my $cap = $rpcenv->compute_api_permission($username);

	    $res = {
		ticket => $ticket,
		username => $username,
		CSRFPreventionToken => $csrftoken,
		cap => $cap,
	    };

	    my $clinfo = PVE::Cluster::get_clinfo();
	    if ($clinfo->{cluster}->{name} && $rpcenv->check($username, '/', ['Sys.Audit'], 1)) {
		$res->{clustername} = $clinfo->{cluster}->{name};
	    }
	};
	if (my $err = $@) {
	    my $clientip = $rpcenv->get_client_ip() || '';
	    syslog('err', "openid authentication failure; rhost=$clientip msg=$err");
	    # do not return any info to prevent user enumeration attacks
	    die PVE::Exception->new("authentication failure\n", code => 401);
	}

	PVE::Cluster::log_msg('info', 'root@pam', "successful openid auth for user '$res->{username}'");

	return $res;
    }});
