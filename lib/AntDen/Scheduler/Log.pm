package AntDen::Scheduler::Log;
use strict;
use warnings;
use JSON;

$|++;

sub new
{
    my ( $class, %this ) = @_;

    map{ die "$_ undefind" unless $this{$_} }qw( path name );
    $this{date} = '';

    my $self = bless \%this, ref $class || $class;

    $self->cut();
    return $self;
}

sub cut
{
    my $this = shift @_;

    my $date = POSIX::strftime( "%Y%m%d", localtime );

    return if $this->{date} eq $date;
    $this->{date} = $date;
    my $file = "$this->{path}/$this->{name}.$this->{date}.log";
    die "open $file fail: $!" unless open $this->{H}, ">>", $file;
}

sub say
{
    my ( $this, $data ) = @_;

    map{ $data->{$_} += 0 if defined $data->{$_} && ( $data->{$_} =~ /^\d+$/ || $data->{$_} =~ /^\d+\.\d+$/ ) }keys %$data;
    syswrite $this->{H}, JSON::to_json( $data )."\n";

    if( my $task = $data->{TASK} )
    {
        for my $taskid ( keys %$task )
        {
            my %d = ( taskid => $taskid, time => $data->{time}, %{$task->{$taskid}} );
            $this->say( \%d );
        }
    }
    return $this;
}

1;
