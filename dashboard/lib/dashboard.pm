package dashboard;
use Dancer ':syntax';
use POSIX;
use FindBin qw( $RealBin );
use MYDan::Util::OptConf;
use AntDen::Scheduler::Ctrl;
use AntDen::Scheduler::DB;
set show_errors => 1;
our $VERSION = '0.1';
our ( $schedulerCtrl, $schedulerDB, %addr, %opt, %code );

BEGIN{
    use FindBin qw( $RealBin );
    map{
        my $code = do( -f "$RealBin/../private/code/$_" ? "$RealBin/../private/code/$_" : "$RealBin/../code/$_" );
        die "code/$_ no CODE" unless ref $code eq 'CODE';
        $code{$_} = $code;
    }qw( sso );

    $MYDan::Util::OptConf::THIS = 'antden';
    %opt = MYDan::Util::OptConf->load()->get()->dump();
    $schedulerCtrl = AntDen::Scheduler::Ctrl->new( %{$opt{scheduler}} );
    $schedulerDB = AntDen::Scheduler::DB->new( $opt{scheduler}{db} );
};

sub get_username
{
    my $callback = sprintf "%s%s%s", config->{ssocallback}, "http://".request->{host},request->{path};
    my $username = &{$code{sso}}( cookie( config->{cookiekey} ) );
    redirect $callback unless $username;
    return $username;
}

get '/logout' => sub {
    redirect config->{ssologout};
};

get '/' => sub {
    return unless my $user = get_username();
    my @machine = $schedulerDB->selectMachineInfoByUser( $user );
    #`ip`,`hostname`,`envhard`,`envsoft`,`switchable`,`group`,`workable`,`role`,`mon`

    my @resources = $schedulerDB->selectResourcesInfoByUser( $user );
    #`ip`,`name`,`id`,`value`
    my ( %r, %t, %used, %use );
    for ( @resources )
    {
        my ( $ip, $name, $id, $value ) = @$_;
        $r{$ip}{$name} += $value;
        $t{$name} += $value;
    }

    for ( @machine )
    {
        my ( $ip, $mon ) = @$_[0,8];
        map{
            my @x = split /=/, $_, 2;
            $used{$ip}{$x[0]} = $x[1] || 0;
        }split ',', $mon;
    }    

    for my $ip ( keys %r )
    {
        map{ $used{$ip}{$_} = $r{$ip}{$_} unless defined $used{$ip}{$_} }keys %{$r{$ip}};
        $r{$ip} = join ',', map{ "$_=$r{$ip}{$_}" } sort keys %{$r{$ip}};
    }
    map{ push @$_, $r{$_->[0]} }@machine;

    for my $v ( values %used )
    {
        map{ $use{$_} += $v->{$_} }keys %$v;
    }

    $t{health} = scalar @machine;
    $t{load} = int( $t{CPU} / 1024 ) if $t{CPU};

    my @total = map{ [ $_, $use{$_}, $t{$_} ] }sort keys %t;
    
    template 'index', +{ machine => \@machine, total => \@total };
};

get '/scheduler/submitJob' => sub {
    return unless my $user = get_username();
    my $param = params();
    my ( $configStr, $niceStr, $groupStr, $nameStr, $err, $jobid )
        = ( $param->{config}, $param->{nice}, $param->{group}, $param->{name}, '', '' );

    if( $configStr )
    {
        unless( defined $niceStr && $niceStr =~ /^\d+$/ )
        {
            $err = 'nice error';
        }elsif( !( defined $groupStr && $groupStr =~ /^[a-zA-Z0-9]+$/ ))
        {
            $err = 'group error';
        }elsif( !( defined $nameStr && $nameStr =~ /^[a-zA-Z0-9_\-\.]+$/ ))
        {
            $err = 'name error';
        }
        else
        {
            my $config = eval{ YAML::XS::Load $param->{config} };
            if( $@ )
            {
                $err = "config format error: $@";
            }
            elsif( ! ( $config && ref $config eq 'ARRAY' ) )
            {
                $err = 'config format error: no ARRAY';
            }
            else
            {
                 my @auth = $schedulerDB->selectAuthByUser( $user, $groupStr );
                 #`executer`
                 my %auth; map{ $auth{$_->[0]} = 1; }@auth;
                 map{ $err = 'no auth' unless $auth{$_->{executer}{name}} }@$config;
                 
                 unless( $err )
                 {
                     $jobid = $schedulerCtrl->startJob( $config, $niceStr, $groupStr, $user, $nameStr );
                     $configStr = '';
                 }
            }
        }
    }
    $niceStr = 5 if ! defined $niceStr;
    template 'scheduler/submitJob', +{ config => $configStr, nice => $niceStr,
        group => $groupStr, name => $nameStr, err => $err, jobid => $jobid };
};

get '/scheduler/job' => sub {
    return unless my $user = get_username();
    my @job = $schedulerDB->selectJobWorkInfoByUser( $user );
    #`id`,`jobid`,`owner`,`name`,`nice`,`group`,`status`,`ingress`
    template 'scheduler/jobs', +{ jobs => \@job };
};

get '/scheduler/ingress' => sub {
    return unless my $user = get_username();
    my @job = $schedulerDB->selectIngressJobByUser( $user );
    #`id`,`jobid`,`nice`,`group`,`status`,`ingress`
    my %ingress; map{ map{ my @x = split /:/, $_; $ingress{$x[0]}++; }split /,/, $_->[5] }@job;
    template 'scheduler/ingress', +{ ingress => [ sort keys %ingress ] };
};

get '/scheduler/ingress/:domain' => sub {
    return unless my $user = get_username();
    my $param = params();
    my $domain = $param->{domain};
    my @job = $schedulerDB->selectIngressJob();
    #`id`,`jobid`,`nice`,`group`,`status`,`ingress`

    my %ingress;
    for my $job ( @job )
    {
        map{
            my @x = split /:/, $_;
            $ingress{$job->[3]}{$job->[1]}++ if $domain eq $x[0];
        }split /,/, $job->[5];
    }

    for my $group (  keys %ingress )
    {
        for my $jobid ( keys %{$ingress{$group}} )
        {
            my @task = $schedulerDB->selectTaskByJobid( $jobid );
            $ingress{$group}{$jobid} = \@task;
        }
    }

    my ( @group, %group )= $schedulerDB->selectIngressMachine();
    #`ip`,`hostname`,`envhard`,`envsoft`,`switchable`,`group`,`workable`,`role`
    map{ push @{$group{$_->[5]}}, $_->[0]; }@group;
    map{ $group{$_} = join ',', @{$group{$_}} }keys %group;
    
    template 'scheduler/ingressInfo', +{ ingress => \%ingress, group => \%group, domain => $domain };
};

get '/scheduler/task/:taskid' => sub {
    return unless my $user = get_username();
    my $param = params();
    my $taskid = $param->{taskid};
    my $config = eval{ YAML::XS::Dump YAML::XS::LoadFile "$opt{scheduler}{conf}/task/$taskid" };

    template 'scheduler/task', +{ config => $config };
};

get '/scheduler/job/:jobid' => sub {
    return unless my $user = get_username();
    my $param = params();
    my $jobid = $param->{jobid};

    return 'noauth' unless my @m = $dashboard::schedulerDB->selectJobByJobidAndOwner( $jobid, $user );

    my @task = $schedulerDB->selectTaskByJobid( $jobid );
    #id,jobid,taskid,hostip,status,result,msg,usetime,domain,location,port
    my @job = $schedulerDB->selectJobByJobid( $jobid );
    #id,jobid,nice,group,status
    my $config = eval{ YAML::XS::Dump YAML::XS::LoadFile "$opt{scheduler}{conf}/job/$jobid" };

    template 'scheduler/job', +{ config => $config, task => \@task, job => $job[0] };
};

get '/scheduler/job/renice/:renice/:jobid' => sub {
    return unless my $user = get_username();
    my $param = params();
    my ( $jobid, $renice ) = @$param{ qw( jobid renice ) };

    return "jobid format error" unless $jobid && $jobid =~ /^J[0-9\.]+$/;
    return "renice format error" unless defined $renice && $renice =~ /^\d+$/;

    $schedulerCtrl->reniceJob( $jobid, $renice );
    return "renice job: $jobid success";
};

get '/scheduler/job/stop/:jobid' => sub {
    return unless my $user = get_username();
    my $param = params();
    my ( $jobid, $owner ) = @$param{qw(jobid owner)};
    return "jobid format error" unless $jobid && $jobid =~ /^J[0-9\.]+$/;
    return "stop job: $jobid fail noauth" unless my @m = $dashboard::schedulerDB->selectJobByJobidAndOwner( $jobid, $owner );
    $schedulerCtrl->stopJob( $jobid );
    return "stop job: $jobid success";
};

get '/scheduler/jobHistory' => sub {
    return unless my $user = get_username();
    my $param = params();
    my $page = $param->{page};
    $page = 0 unless $page && $page =~ /^\d+$/;
    my @job = $schedulerDB->selectJobStopedInfoByOwnerPage( $user , $page * 50, 50 );
    #`id`,`jobid`,`owner`,`name`,`nice`,`group`,`status`
    template 'scheduler/jobHistory', +{ jobs => \@job, page => $page, joblen => scalar @job };
};

get '/tasklog/:uuid' => sub {
    return unless my $user = get_username();
    my $uuid = params()->{uuid};
    my $ws_url = request->env->{HTTP_HOST};
    $ws_url =~ s/:\d+$//;
    $ws_url .= ":3001";
    $ws_url = "ws://$ws_url/ws";
    template 'scheduler/tasklog', +{ ws_url => $ws_url, uuid => $uuid };
};

any '/mon' => sub {
    eval{ $schedulerDB->selectMon() if $schedulerDB->isMysql() };
    return $@ ? "ERR:$@" : "ok";
};

true;
