#!/usr/bin/perl 

my $default_moo_host = "moo.hellyeah.com";
my $default_moo_port = 7777;
my $ID = "moojab.hellyeah.com";

# Do Not Touch stuff below here
# unless you know what you are doing
#################################

use strict;
use Moo;
use Jabber::Connection;
use Jabber::NodeFactory;
use Jabber::NS qw(:all);
use MLDBM 'DB_File';
use POSIX qw(setsid);
use Getopt::Std;

my $NAME = "Jabber-Moo Transport";
my $VERSION = '0.1';
my $reg_file = "/var/jabber/spool/moojab.hellyeah.com/registrations";
my %reg;
my @sessions;
my $DEBUG = 0;  

our($opt_d, $opt_h);
getopts("dh");
if ($opt_d)
{
	$DEBUG = 1;
}
if ($opt_h)
{	
	print "usage: \n";
	print " -d	enable debuging output, run in foreground\n";
	print " -h 	display this message\n\n";
	exit
}

tie (%reg, 'MLDBM', $reg_file) or die "Cannot tie to $reg_file: $!\n";


my $jabber = new Jabber::Connection(
		server 		=> 'localhost:9999',
		localname 	=> $ID,
		ns 		=> 'jabber:component:accept',
		log		=> $DEBUG,
		debug		=> $DEBUG,
		);



unless ($jabber->connect()) 
{
	die "couldn't connect to jabber: " . $jabber->lastError; 
}

if ($DEBUG == 0)
{
	daemonize();
}

$SIG{HUP} = $SIG{KILL} = $SIG{TERM} = $SIG{INT} = \&signal_handler;


debug("registering IQ handlers");
$jabber->register_handler('iq',\&iq_version);
$jabber->register_handler('iq',\&iq_browse);
$jabber->register_handler('iq',\&iq_register);
$jabber->register_handler('iq',\&iq_notimpl);
$jabber->register_handler('presence',\&presence);

$jabber->register_handler('message',\&jab_message);

debug("registering beat");
$jabber->register_beat(20, \&session_manager);
$jabber->register_beat(1, \&read_moo);

debug("authenticating");
$jabber->auth('moojab');

debug("running first pass session manager");
session_manager();

send_presence("online");

debug("starting loop");
$jabber->start;


sub send_presence
{
	my $status = shift;
	my $nf = new Jabber::NodeFactory;
	debug("[sending presence]");
	foreach my $session (@sessions)
	{
		my $to = $session->{jid};
		my $from = $to;
		$from =~ s/@/%/;
		$from = join ('@', $from , $ID);

		my $component_presence = $nf->newNode('presence');
		$component_presence->attr('to', $to);
		$component_presence->attr('from', $ID);
		if ($status eq "offline")
		{
			$component_presence->attr('type', 'unavailable');
		}
		
		my $session_presence = $nf->newNode('presence');
		$session_presence->attr('to', $to);
		$session_presence->attr('from', $from);
		if ($status eq "offline")
		{
			$session_presence->attr('type', 'unavailable');
		}

		debug("--> from $ID to $to");
		$jabber->send($component_presence);

		debug("--> from $from to $to");
		$jabber->send($session_presence);
	}
}

sub read_moo
{
	
	debug("[runing read_moo]");
	my $session_count = @sessions;
	debug("--> active sessions to read: $session_count");
	foreach my $session (@sessions)
	{
		debug("---> reading for jid: $session->{jid}");
		while (my $line = $session->{moo}->getline())
		{
			chomp $line;
			debug($line);
			send_jab($session->{jid},$line); 
		}
	}	
}

sub send_jab
{
	my $jid = shift;
	my $message = shift;
	my $nf = new Jabber::NodeFactory;
	my $from = $jid;
	$from =~ s/@/%/;

	my $msg = $nf->newNode('message');
	$msg->attr('type', 'chat');
	$msg->attr('from', join('@', $from, $ID));
	$msg->attr('to', $jid);
	$msg->insertTag('body')->data($message);

	debug("sending: $message to $jid");

	$jabber->send($msg);
}

sub send_moo
{
	my $jid = shift;
	my $message = shift;

	my $session_object = _lookup_session($jid);

	if (defined($session_object))
	{
		$session_object->{moo}->write($message);
	}
	else
	{
		debug("ERROR: no session defined for $jid");
	}
}

sub jab_message
{
	my $node = shift;
	debug("[jabber message]");
	return unless $node->attr('type', 'chat');

	my $jid = stripJID($node->attr('from'));

	my $body = $node->getTag('body');
	my $message = $body->data;

	debug("got jabber message: $message from jid: $jid");

	send_moo($jid,$message);

}


sub session_manager
{
	my $session_count = @sessions;
	my $registration_count = reg_count();

	debug("[running the session manaager]");	
	debug("--> active sessions: $session_count");
	debug("--> active registrations: $registration_count ");
	if (($session_count) == 0 and ($registration_count > 0)) 
	{
		debug("---> session manager first run, creating sessions for all registered users");
		foreach my $jid (keys %reg)
		{
			debug("----> creating session for jid: $jid");
			_create_session($jid);
		}
	}
	elsif ($registration_count > $session_count)
	{
		debug("---> adding sessions for new user(s)");
		# there are existing sessions in the pool, need to find out who needs 
		# a new session created, it would also be good to check any sessions have
		# died and need restarting.

		foreach my $jid (keys %reg)
		{
			my $create_flag = 1;	
			foreach my $index (@sessions)
			{
				debug($index->{jid});
				if ($jid eq $index->{jid})
				{
					debug("---> found registered jid: $jid in active sessions");
					$create_flag = 0;
				}
			}
			if ($create_flag == 1)
			{
					debug("creating session for jid: " . $jid);
					_create_session($jid);
			}
		}
	}
}


sub _create_session
{
	my $jid = shift;
	
	my $reg_entry = $reg{$jid};
	my $session_object = {};
	$session_object->{jid} = $jid;
	$session_object->{moo} = new Moo(
				host => $reg_entry->{host},
				port => $reg_entry->{port},
				user => $reg_entry->{user},
				password => $reg_entry->{password},
				);
	$session_object->{active} = 0;
	$session_object->{moo}->connect();
	$session_object->{active} = 1;
	push @sessions, $session_object;
	$session_object->{moo}->write(":[is connected via the jabber - moo transport]");
}

sub _lookup_session
{
	my $jid = shift;

	foreach my $lookup (@sessions)
	{
		if ($jid eq $lookup->{jid})
		{
			return $lookup;
		}
	}
	return undef;
}


### for debugging session pool
sub dump_sessions
{
	debug("[DUMPING SESSION POOL]");
	for my $href (@sessions)
	{
		print "{ ";
		for my $role ( keys %$href )
		{
			print "$role=$href->{$role} ";
		}
		print "}\n";
	}
}


sub presence
{
	my $node = shift;
	my $nf = new Jabber::NodeFactory;
	debug("[presence]");
	if (defined($node->attr('type')))
	{
		if ($node->attr('type') eq 'subscribe')
		{
			$node = toFrom($node);
			$jabber->send($node);
			$node->attr('type', 'subscribed');
			$jabber->send($node);
		}
		if ($node->attr('type') eq 'probe')
		{
			my $presence = $nf->newNode('presence');
			$presence->attr('from', $node->attr('to'));
			$presence->attr('to', $node->attr('from'));
			$jabber->send($presence);
		}
		if ($node->attr('type') eq 'unavailable')
		{
			# for now we'll just let the moo users know that this 
			# user is blind in a comical way.
			# if the session manager gets smarter, will need this to 
			# take this users session offline, or mark it offline in
			# the @sessions so session_manager can take it offline.

			my $from = stripJID($node->attr('from'));
			send_moo($from, ":passes out from all the excitement");
			send_moo($from, "idle not here");
		}
	}
	else
	{
		# no type set, so must be a change of online status
		# lets update the moo for that.


		my $show;
		my $status;
		my $from = stripJID($node->attr('from'));
		if (defined($node->getTag('show')))
		{
			$show = $node->getTag('show')->data();
		
			if (defined($node->getTag('status')))
			{
				$status = $node->getTag('status')->data();
				if ($show eq "chat")
				{
					$status = "doing " . $status;
				}	
				elsif ($show eq "away")
				{
					if (defined($status))
					{
						$status = "idle " . $status;
					}
					else 
					{
						$status = "idle";
					}
				}
			}
		}
		else
		{
			# this is a plain old presence so clear any in moo status

			$status = "undoing";
		}	

		debug("SENDING: status: $status to jid: $from");
		send_moo($from, $status);
		
	}
}


sub iq_register
{
	my $node = shift;
	debug("[iq_register]");
	return unless my $query = $node->getTag('', NS_REGISTER);
	debug("--> registration request");

	# Registration query
	if ($node->attr('type') eq IQ_GET)
	{
		debug("---> getting registration form");
		$node = toFrom($node);
		$node->attr('type', IQ_RESULT);
		my $instructions = "Register with the Jabber-Moo Transport?\n\nPlease keep in mind that your moo password is stored and transmited in the clear, and should not be the same as any other password.\n\nThis transport is capable of talking to any moo, however most jabber clients will not display the host and port fields.  These fields default to $default_moo_host:$default_moo_port\n\n";
		$query->insertTag('instructions')->data($instructions);
		$query->insertTag('hostname');
		$query->insertTag('port');
		$query->insertTag('username');
		$query->insertTag('password');
		$jabber->send($node);
	}
	
	# Registration request
	if ($node->attr('type') eq IQ_SET)
	{
		#strip JID to user@host
		my $jid = stripJID($node->attr('from'));
		debug("---> registration request for $jid");
		$node = toFrom($node);

		# Could be an unregister
		if ($query->getTag('remove'))
		{
			debug("----> removing registration for $jid");
			delete $reg{$jid};
			$node->attr('type', IQ_RESULT);
		}
		elsif ((my $moo_user = $query->getTag('username')->data) and 
			(my $moo_password = $query->getTag('password')->data))
		{
			debug("----> username: $moo_user, password: $moo_password");
			
			my $user_reg = $reg{$jid};
			$user_reg->{user} = $moo_user;
			$user_reg->{password} = $moo_password;
			if (defined($query->getTag('hostname')))
			{
				$user_reg->{host} = $query->getTag('hostname')->data;
			}
			else
			{
				$user_reg->{host} = $default_moo_host;
			}
			if (defined($query->getTag('port')))
			{
				$user_reg->{port} = $query->getTag('port')->data;
			}
			else
			{
				$user_reg->{port} = $default_moo_port;
			}
			$reg{$jid} = $user_reg;
		
			$node->attr('type', IQ_RESULT);
		}
		else 
		{
			$node->attr('type', IQ_ERROR);
			my $error = $node->insertTag('error');
			$error->attr('code', '405');
			$error->data('Not Allowed');
		}
	
		$jabber->send($node);
	}

	return r_HANDLED;
}


sub iq_version 
{
	my $node = shift;
	debug("[iq_version]");
	return unless $node->attr('type') eq IQ_GET
		and my $query = $node->getTag('', NS_VERSION);
	debug("--> version request");
	$node = toFrom($node);
	$node->attr('type', IQ_RESULT);

	$query->insertTag('name')->data($NAME);
	$query->insertTag('version')->data($VERSION);
	$query->insertTag('os')->data(`uname -sr`);

	$jabber->send($node); 
	return r_HANDLED;
}


sub iq_browse
{
        my $node = shift;
        debug ("[iq_browse]");
        return unless (($node->attr('type') eq IQ_GET) and (my $query = $node->getTag('', NS_BROWSE)));
        debug ("--> browse request");
        $node = toFrom($node);
        $node->attr('type', IQ_RESULT);
	$query->attr('category', 'service');
	$query->attr('type', 'moo');
	$query->attr('name', $NAME);
	$query->attr('jid', $ID);
	$query->insertTag('ns')->data(NS_REGISTER);
	$query->insertTag('ns')->data(NS_GATEWAY);
	$query->insertTag('ns')->data(NS_VERSION);
	$query->insertTag('ns')->data(NS_BROWSE);
        $jabber->send($node);   
        return r_HANDLED;
}


sub iq_notimpl 
{
	my $node = shift;
	$node = toFrom($node);
	$node->attr('type', IQ_ERROR);
	my $error = $node->insertTag('error');
	$error->attr('code', '501');
	$error->data('Not Implemented');
	$jabber->send($node);

	return r_HANDLED;

}


sub toFrom 
{
	my $node = shift;
	my $to = $node->attr('to');
	$node->attr('to', $node->attr('from'));
	$node->attr('from', $to);
	return $node;
}

sub stripJID 
{
	my $JID = shift;
	$JID =~ s|/.*$||;
	return $JID;
}

sub reg_count
{
	my $count = 0;
	foreach my $jid (keys %reg)
	{
		$count++;
	}
	return $count;
}	

sub daemonize
{
	chdir('/') or die "couldn't chdir to /: $!";
	open(STDIN, '/dev/null') or die "couldn't redirect STDIN to /dev/null: $!";
	open(STDOUT, '>>/dev/null') or die "couldn't redirect STDOUT to /dev/null: $!";
	open(STDERR, '>>/dev/null') or die "couldn't redirect STDERR to /dev/null: $!";
	defined(my $pid = fork()) or die "couldn't fork: $!";
	exit if $pid;
	setsid();
}


sub signal_handler
{
	debug("[shutting down]");

	send_presence("offline");

	debug("[dumping registrations]");
	foreach my $jid (keys %reg) 
	{
		print "\n";
		print "JID: $jid\n";
		my $user_reg = $reg{$jid};
		print "->host: $user_reg->{host}\n";
		print "->port: $user_reg->{port}\n";
		print "->user: $user_reg->{user}\n";
		print "->pass: $user_reg->{password}\n";
		print "\n";
	}	
	dump_sessions();

	untie %reg;
	$jabber->disconnect();

	exit;
}

sub debug {
  	if ($DEBUG == 1) 
	{
		print STDERR "debug: ", @_, "\n";
	}
}
