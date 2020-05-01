#!/usr/bin/perl -w
package Moo;
use strict;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;
$VERSION = 0.01;
@ISA = qw(Exporter);


use Net::Telnet ();
use Carp;

my %data = (
	host 	=> "localhost",
	port	=> 7777,
	user	=> "",
	password => "",
	moo => undef,
	);


sub new
{
	my ($class) = shift;
	my $self = {
		%data,
		};
	my %args;
	local $_;

	bless $self, $class;

	#parse args (if any)
	if (@_ > 1) 
	{
		(%args) = @_;
		foreach(keys %args)
		{
			if (/^-?host$/i)
			{
				$self->host($args{$_});
			}
			if (/^-?port$/i)
			{	
				$self->port($args{$_});
			}
			if (/^-?user$/i)
			{	
				$self->user($args{$_});
			}
			if (/^-?password$/i)
			{
				$self->password($args{$_});
			}
		}
	}

	return $self;
}

sub connect
{
	my $self = shift;

	#
	# Connect to the moo via telnet on the specified host and port
	#
	#  	this will need more error checking if this is to be publicly 
	#	released.
	#
	$self->{moo} = new Net::Telnet (
			Host => $self->host,
			Port => $self->port,
			Timeout => 1,
			Errmode => "return"
				) or die $!;

	#
	# Read from the moo until it stops writing (this will get us the pre-login banner
	#
	my $banner = $self->read;
	while (my $line = $self->{moo}->getline)
	{
		$banner = $banner . $line;
	}

	my $connect_string = "connect " . $self->user . " " . $self->password; 

	my $retval = $self->write($connect_string);
	
	$banner = $banner . $self->read;

	return $banner;
}


sub read 
{
	my $self = shift;

	my $read_buffer = "";
	while (my $line = $self->{moo}->getline)
	{
		$read_buffer = $read_buffer . $line;
	}

	return $read_buffer;
}

sub getline 
{
	my $self = shift;
	
	$self->{moo}->timeout(0);
	return $self->{moo}->getline;
}


sub write
{
	my $self = shift;
	my $write_buffer = shift;
	$write_buffer = $write_buffer . "\n";
	return $self->{moo}->put($write_buffer);
}


# Accessor Functions 

sub host
{
	my $self = shift;
	my $prev = $self->{host};
	if (@_) { $self->{host} = shift } 
	return $prev
}

sub port
{
	my $self = shift;
	my $prev = $self->{port};
	if (@_) { $self->{port} = shift }
	return $prev
}

sub user
{
	my $self = shift;
	my $prev = $self->{user};
	if (@_) { $self->{user} = shift }
	return $prev
}

sub password
{
	my $self = shift;
	my $prev = $self->{password};
	if (@_) { $self->{password} = shift }
	return $prev;
}


# Module needs to return true
1;
