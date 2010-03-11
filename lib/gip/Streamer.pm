package Streamer;

# Class vars
# Global options
my $optref;
my $opt;


# Constructor
# Usage: $streamer = Streamer->new();
sub new {
	my $type = shift;
	my %params = @_;
	my $self = {};
	for (keys %params) {
		$self->{$_} = $params{$_};
	}
	# Ensure the subclass $opt var is pointing to the Superclass global optref
	$opt = $Streamer::optref;
	bless $self, $type;
}


# Use to bind a new options ref to the class global $optref var
sub add_opt_object {
	my $self = shift;
	$Streamer::optref = shift;
}


# $opt->{<option>} access method
sub opt {
	my $self = shift;
	my $optname = shift;
	return $opt->{$optname};
}

