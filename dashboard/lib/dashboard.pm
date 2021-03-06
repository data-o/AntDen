package dashboard;
use Dancer ':syntax';
use POSIX;
use AntDen;
use Digest::MD5;
use FindBin qw( $RealBin );
use File::Basename;
use MYDan::Util::OptConf;
use AntDen::Scheduler::Ctrl;
use AntDen::Scheduler::DB;
set show_errors => 1;
our $VERSION = '0.1';
our ( $schedulerCtrl, $schedulerDB, %addr, %opt, %code, $ssoconfig );

BEGIN{
    use FindBin qw( $RealBin );
    map{
        my $code = do( -f "$RealBin/../private/code/$_" ? "$RealBin/../private/code/$_" : "$RealBin/../code/$_" );
        die "code/$_ no CODE" unless ref $code eq 'CODE';
        $code{$_} = $code;
    }qw( sso ssoconfig );
    $ssoconfig = &{$code{ssoconfig}}();

    $MYDan::Util::OptConf::THIS = 'antden';
    %opt = MYDan::Util::OptConf->load()->get()->dump();
    $schedulerCtrl = AntDen::Scheduler::Ctrl->new( %{$opt{scheduler}} );
    $schedulerDB = AntDen::Scheduler::DB->new( $opt{scheduler}{db} );
};

sub get_username
{
    my $alone = shift @_;
    my $callback = sprintf "%s%s%s", $ssoconfig->{ssocallback}, "http://".request->{host},request->{path};
    my $username = &{$code{sso}}( cookie( $ssoconfig->{cookiekey} ), $schedulerDB );
    redirect $callback if ! $alone && ! $username;
    return $username;
}

get '/logout' => sub {
    redirect $ssoconfig->{ssologout} || '/default/logout';
};

get '/default/logout' => sub {
    template 'default/logout', +{ cookiekey => $ssoconfig->{cookiekey} };
};

get '/chpasswd' => sub {
    return template 'msg', +{ msg => 'Unsupported'  } unless $ssoconfig->{chpasswd};
    redirect $ssoconfig->{chpasswd};
};

get '/' => sub {
    my $user = get_username(1);
    template 'index', +{ usr => $user };
};

get '/resources' => sub {
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
        $_->[8] = $_->[8] =~ /health=1/ ? 'health=1' : 'health=0';
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
    
    template 'resources', +{ machine => \@machine, total => \@total, usr => $user };
};

get '/datasets' => sub {
    return unless my $user = get_username();
    my @datasets = $schedulerDB->selectDatasetsByUser( $user );
    #id,name,info,type,group,token
    template 'datasets', +{ datasets => \@datasets, usr => $user };
};

get '/scheduler/submitJob' => sub {
    return unless my $user = get_username();
    my $param = params();
    my ( $configStr, $niceStr, $groupStr, $nameStr, $err, $jobid )
        = ( $param->{config}, $param->{nice}, $param->{group}, $param->{name}, '', '' );

    my ( @auth, %group ) = $dashboard::schedulerDB->selectOrganizationauthByUser( $user );
    #`id`,`name`,`user`,`role`
    map{ $group{$_->[1]} = 1; }@auth;

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
                 my $auth = 0;
                 map{
                     $auth = $_->[3] if ( $_->[2] eq '_public_' || $_->[2] eq $user ) && $groupStr eq $_->[1] && $_->[3] > $auth;
                 }@auth;
                 my %match = ( exec => 2, docker => 1 );
                 map{
                     my $match = defined $match{$_->{executer}{name}} ? $match{$_->{executer}{name}} : 2;
                     $err = 'no auth' unless $auth >= $match;
                 }@$config;
                 
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
        group => $groupStr, name => $nameStr, err => $err, jobid => $jobid,
        tt => 'scheduler/submitJob/default.tt', cmdsj => cmdsj( %group ), usr => $user };
};

sub cmdsj
{
    my ( %g, %x ) = @_;
    map{
         $_ =~ s/\.tt$//;
         $_ =~ /^([a-z]+)/;
         my $n = $1 || 'default';
         push( @{$x{$n}}, $_ ) if $g{$n};
    }sort map{ basename $_ }
    glob "$AntDen::PATH/dashboard/views/scheduler/submitJob/cmd/*";

    $x{key} = [ sort keys %x ];
    return \%x;
}

get '/scheduler/submitJob/cmd/:name' => sub {
    return unless my $user = get_username();
    my $param = params();

    my $cts = config->{cts}{$param->{name}};
    if( $param->{cmd} && $cts )
    {
        my $md5 = Digest::MD5->new->add( $param->{cmd} )->hexdigest;
        return template 'msg', +{ err => "Command template security check failed: $md5: $param->{cmd}"  } unless $cts->{$md5};
    }

    my ( @auth, %group ) = $dashboard::schedulerDB->selectOrganizationauthByUser( $user );
    #`id`,`name`,`user`,`role`
    map{ $group{$_->[1]} = 1; }@auth;

    my ( $err, $jobid, $uuid, @ip ) = ( '', '' );

    my $ws_url = request->env->{HTTP_HOST};
    $ws_url =~ s/:\d+$//;
    $ws_url .= ":3001";
    $ws_url = "ws://$ws_url/ws";

    $param->{username} ||= $user;
    my $authgroup = $param->{name} =~ /^([a-z]+)/ ? $1 : 'default';
    $param->{group} = $authgroup;
    
    if( $param->{cmd} )
    {
        unless( $param->{ip} )
        {
            map{
                $param->{ip} = $_->[0] if $_->[8] =~ /health=1/;
                push( @ip, $_->[0] ) if $_->[8] =~ /health=1/ && $_->[7] eq 'slave' && $param->{allslave};
            }$schedulerDB->selectMachineInfoByGroup( $param->{group} );
        }

        $err = "ip error:$param->{ip}" unless $param->{ip} && $param->{ip} =~ /^\d+\.\d+\.\d+\.\d+$/;
        $err = "group error:$param->{group}" unless $param->{group} && $param->{group} =~ /^[a-z0-9_\.\-]+$/;
        $err = "cmd err:$param->{cmd}" unless $param->{cmd} && $param->{cmd} =~ /^[\/a-zA-Z0-9_:'\.\- ]+$/;
    
        @ip = ( $param->{ip} ) unless @ip;
        my $cmd = $param->{cmd};
        my @arg = $cmd =~ /:::([a-zA-Z0-9]+):::/g;
        map{
            $cmd =~ s/:::${_}:::/$param->{$_}/g;
            $err = "$_ err" unless defined $param->{$_} && $param->{$_} =~ /^[\^\.\/a-zA-Z0-9_:%\.\@\-]+$/;
        }@arg;

        if( ( @arg == grep{ $param->{$_} }@arg ) && ! $err )
        {
             my $config = [
                 map{ +{
                     executer => +{
                         name => 'exec',
                         param => +{
                             exec => $cmd
                         },
                     },
                     scheduler => +{
                         envhard => 'arch=x86_64,os=Linux',
                         envsoft => 'app1=1.0',
                         count => 1,
                         ip => $_,
                         resources => [ [ 'CPU', '.', 2 ] ]
                    }
                 } }@ip
             ];
             my $auth = 0;
             map{
                $auth = $_->[3] if ( $_->[2] eq '_public_' || $_->[2] eq $user ) && $authgroup eq $_->[1] && $_->[3] > $auth;
             }@auth;
 
             $err = 'no auth' unless $auth;

             unless( $err )
             {
                 $jobid = $schedulerCtrl->startJob( $config, 5, $param->{group}, $user, $param->{name} );
                 $uuid = $jobid. ".001_$ip[0].log";
                 $uuid =~ s/^J/T/;
             }
        }
    }

    template 'scheduler/submitJob', +{ err => $err, jobid => $jobid, host => request->{host}, usr => $user,
        tt => "scheduler/submitJob/cmd/" . $param->{name} . ".tt", ws_url => $ws_url, uuid => $uuid, cmdsj => cmdsj( %group ) };
};

get '/scheduler/job' => sub {
    return unless my $user = get_username();
    my @job = $schedulerDB->selectJobWorkInfoByUser( $user );
    #`id`,`jobid`,`owner`,`name`,`nice`,`group`,`status`,`ingress`
    template 'scheduler/jobs', +{ jobs => \@job, usr => $user };
};

get '/scheduler/ingress' => sub {
    return unless my $user = get_username();
    my @job = $schedulerDB->selectIngressJobByUser( $user );
    #`id`,`jobid`,`nice`,`group`,`status`,`ingress`
    my %ingress; map{ map{ my @x = split /:/, $_; $ingress{$x[0]}++; }split /,/, $_->[5] }@job;
    template 'scheduler/ingress', +{ usr => $user, ingress => [ sort keys %ingress ] };
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
    
    template 'scheduler/ingressInfo', +{ ingress => \%ingress, group => \%group, domain => $domain, usr => $user };
};

get '/scheduler/task/:taskid' => sub {
    return unless my $user = get_username();
    my $param = params();
    my $taskid = $param->{taskid};
    my $config = eval{ YAML::XS::Dump YAML::XS::LoadFile "$opt{scheduler}{conf}/task/$taskid" };

    template 'scheduler/task', +{ config => $config, usr => $user };
};

get '/scheduler/job/:jobid' => sub {
    return unless my $user = get_username();
    my $param = params();
    my $jobid = $param->{jobid};

    return 'noauth' unless my @m = $dashboard::schedulerDB->selectJobByJobidAndOwner( $jobid, $user, $user );

    my @task = $schedulerDB->selectTaskByJobid( $jobid );
    #id,jobid,taskid,hostip,status,result,msg,usetime,domain,location,port
    my @job = $schedulerDB->selectJobByJobid( $jobid );
    #id,jobid,nice,group,status
    my $config = eval{ YAML::XS::Dump YAML::XS::LoadFile "$opt{scheduler}{conf}/job/$jobid" };

    template 'scheduler/job', +{ config => $config, task => \@task, job => $job[0], usr => $user };
};

get '/scheduler/job/renice/:renice/:jobid' => sub {
    return unless my $user = get_username();
    my $param = params();
    my ( $jobid, $renice ) = @$param{ qw( jobid renice ) };

    return "jobid format error" unless $jobid && $jobid =~ /^J[0-9\.]+$/;
    return "renice format error" unless defined $renice && $renice =~ /^\d+$/;

    return "renice job: $jobid fail noauth" unless my @m = $dashboard::schedulerDB->selectJobByJobidAndOwner( $jobid, $user, $user );
    $schedulerCtrl->reniceJob( $jobid, $renice );
    return "renice job: $jobid success";
};

get '/scheduler/job/stop/:jobid' => sub {
    return unless my $user = get_username();
    my $param = params();
    my $jobid = $param->{jobid};
    return "jobid format error" unless $jobid && $jobid =~ /^J[0-9\.]+$/;
    return "stop job: $jobid fail noauth" unless my @m = $dashboard::schedulerDB->selectJobByJobidAndOwner( $jobid, $user, $user );
    $schedulerCtrl->stopJob( $jobid );
    return "stop job: $jobid success";
};

get '/scheduler/jobHistory' => sub {
    return unless my $user = get_username();
    my $param = params();
    my $page = $param->{page};
    $page = 0 unless $page && $page =~ /^\d+$/;
    my $pagesize = 50;
    my @job = $schedulerDB->selectJobStopedInfoByOwnerPage( $user , $page * $pagesize, $pagesize );
    #`id`,`jobid`,`owner`,`name`,`nice`,`group`,`status`
    template 'scheduler/jobHistory', +{ jobs => \@job, page => $page, pagesize => $pagesize, usr => $user, joblen => scalar @job };
};

get '/tasklog/:uuid' => sub {
    return unless my $user = get_username();
    my $uuid = params()->{uuid};
    my $ws_url = request->env->{HTTP_HOST};
    $ws_url =~ s/:\d+$//;
    $ws_url .= ":3001";
    $ws_url = "ws://$ws_url/ws";
    template 'scheduler/tasklog', +{ ws_url => $ws_url, uuid => $uuid, usr => $user };
};

any '/mon' => sub {
    eval{ $schedulerDB->selectMon() if $schedulerDB->isMysql() };
    return $@ ? "ERR:$@" : "ok";
};

true;
