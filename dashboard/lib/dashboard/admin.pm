package dashboard::admin;
use dashboard;
use Dancer ':syntax';
set show_errors => 1;
our $VERSION = '0.1';

sub adminInfo
{
    my $callback = sprintf "%s%s%s", config->{ssocallback}, "http://".request->{host},request->{path};
    my $username = &{$dashboard::code{sso}}( cookie( config->{cookiekey} ) );
    redirect $callback unless $username;
    my @x = $dashboard::schedulerDB->selectIsAdmin( $username );
    my $level = 0; map{ $level = $_->[2] if $level < $_->[2] }@x;
    return ( $username, $level );
}

get '/admin' => sub {
    my ( $username, $level ) = adminInfo();
    return 'Unauthorized:'. $username unless $level;
    template 'admin', +{ admin => 1 };
};

get '/admin/authorization/user' => sub {
    my ( $username, $level ) = adminInfo();
    return 'Unauthorized:'. $username unless $level;
    my $param = params();

    $dashboard::schedulerDB->insertAuth( $param->{user}, $param->{group}, $param->{executer} )
        if $param->{user} && $param->{group} && $param->{executer};

    $dashboard::schedulerDB->deleteAuthById( $param->{deleteid} ) if $param->{deleteid};

    my @auth = $dashboard::schedulerDB->selectAuth();
    template 'admin/authorization/user', +{ admin => 1, auth => \@auth };
};

get '/admin/authorization/admin' => sub {
    my ( $username, $level ) = adminInfo();
    return 'Unauthorized:'. $username unless $level;
    my $param = params();

    if( $level > 1 )
    {
        $dashboard::schedulerDB->insertAdmin( $param->{user} ) if $param->{user};
        $dashboard::schedulerDB->deleteAdminById( $param->{deleteid} ) if $param->{deleteid};
    }

    my @user = $dashboard::schedulerDB->selectIsAdminAll();
    template 'admin/authorization/admin', +{ admin => 1, user => \@user, level => $level };
};

get '/admin/log/slave' => sub {
    my ( $username, $level ) = adminInfo();
    return 'Unauthorized:'. $username unless $level;

    my @machine = $dashboard::schedulerDB->selectMachineInfo();
    #`ip`,`hostname`,`envhard`,`envsoft`,`switchable`,`group`,`workable`,`role`,`mon`
    template 'admin/log/slave', +{ admin => 1, machine => \@machine };
};

get '/admin/tasklog/:uuid' => sub {
    my ( $username, $level ) = adminInfo();
    return 'Unauthorized:'. $username unless $level;
    my $uuid = params()->{uuid};
    my $ws_url = request->env->{HTTP_HOST};
    $ws_url =~ s/:\d+$//;
    $ws_url .= ":3001";
    $ws_url = "ws://$ws_url/ws";
    template 'admin/tasklog', +{ admin => 1, ws_url => $ws_url, uuid => $uuid };
};

true;