package dashboard::organization;
use Dancer ':syntax';
use JSON;
use dashboard;
our $VERSION = '0.1';

our ( %role2id, %id2role );
BEGIN{
    my @role = ( 'void', 'guest', 'master', 'owner' );
    map{ $role2id{$role[$_]} = $_; $id2role{$_} = $role[$_]; } 0.. $#role;

};
get '/organization' => sub {
    my  $param = params();
    return unless my $username = dashboard::get_username();

    my $err;
    if( 2 eq grep{ $param->{$_} }qw( name describe ) )
    {
        #TODO
        if( $dashboard::schedulerDB->selectOrganizationByName( $param->{name} ) )
        {
            $err = 'Organization already exists, please use another name';
        }
        else
        {
            $dashboard::schedulerDB->insertOrganization( $username, @$param{qw( name describe ) } );
            $dashboard::schedulerDB->insertOrganizationauth( $param->{name}, $username, 3 );
        }
    }

    my %group = +{ owner => [], guest => [], master => [], public => [] };
    my @o = $dashboard::schedulerDB->selectOrganizationauthByUser( $username );
    #`id`,`name`,`user`,`role`
    map{
        push @{$group{ $_->[2] eq '_public_' ? 'public' : $id2role{$_->[3]}}}, $_->[1]
    }@o;

    template 'organization', +{ %group, usr => $username, err => $err };
};

get '/organization/:groupname' => sub {
    my $param = params();
    return unless my $username = dashboard::get_username();

    my ( $err ,$err2, $err3 );
    my %group = +{ owner => [], guest => [], master => [], public => [] };
    my @o = $dashboard::schedulerDB->selectOrganizationauthByUser( $username );
    #`id`,`name`,`user`,`role`
    map{
        push @{$group{ $_->[2] eq '_public_' ? 'public' : $id2role{$_->[3]}}}, $_->[1]
    }@o;

    my @members = $dashboard::schedulerDB->selectOrganizationauthByName( $param->{groupname} );
    #`id`,`name`,`user`,`role`

    my $myrole = 0;
    map{

        $myrole = $_->[3] if ( $_->[2] eq '_public_' || $_->[2] eq $username ) && $_->[3] > $myrole;
    }@members;

   return template 'msg', +{ %group, usr => $username, err => 'Permission denied' } unless $myrole;

    my @machine = $dashboard::schedulerDB->selectMachineInfoByGroup( $param->{groupname} );
    #`ip`,`hostname`,`envhard`,`envsoft`,`switchable`,`group`,`workable`,`role`,`mon`
    map{ $_->[8] = $_->[8] =~ /health=1/ ? 'health=1' : 'health=0' }@machine;

    my @datasets = $dashboard::schedulerDB->selectDatasetsByGroup( $param->{groupname} );
    #`id`,`name`,`info`,`type`

    if( 2 eq grep{ $param->{$_} }qw( user role ) )
    {
        if( $myrole <= 1 ) { $err = 'Permission denied'; }
        elsif( $param->{role} >= $myrole )
        {
            $err = 'You can only add roles with lower permissions than you';
        }
        else
        {
            $dashboard::schedulerDB->insertOrganizationauth( @$param{qw( groupname user role ) } );
            @members = $dashboard::schedulerDB->selectOrganizationauthByName( $param->{groupname} );
        }
    }

    my $currentlyvisibility = 'private';
    map{ $currentlyvisibility = 'public' if $_->[2] eq '_public_'; }@members;

    if( $param->{deleteid} )
    {
        my $delrole = 4;
        map{ $delrole = $_->[3] if $_->[0] eq $param->{deleteid} }@members;
        if( $delrole < $myrole )
        {
            $dashboard::schedulerDB->deleteOrganizationauthById( $param->{deleteid} );
            @members = $dashboard::schedulerDB->selectOrganizationauthByName( $param->{groupname} );
        }
        else { $err = 'Permission denied'; }
    }

    if( $param->{deleteDatasetsId} )
    {
        if( $myrole >= 2 )
        {
            $dashboard::schedulerDB->deleteDatasetsByIdAndGroup( $param->{deleteDatasetsId}, $param->{groupname} );
            @datasets = $dashboard::schedulerDB->selectDatasetsByGroup( $param->{groupname} );
        }
        else { $err2 = 'Permission denied'; }
    }

    if( $param->{deleteMachineIp} )
    {
        if( $myrole >= 2 && grep{ $_->[0] eq $param->{deleteMachineIp} }@machine )
        {
            $dashboard::schedulerCtrl->delMachine( $param->{deleteMachineIp} );
            $err3 = 'The delete task has been submitted and will take effect in a few seconds';
        }
        else { $err3 = 'Permission denied'; }
    }

    map{ $_->[3] = $id2role{$_->[3]} }@members;

    my @org = $dashboard::schedulerDB->selectOrganizationByName( $param->{groupname} );
    #`id`,`name`,`describe`
    my @job = $dashboard::schedulerDB->selectJobWorkInfoByGroup( $param->{groupname} );

    template 'organization/one', +{
        %group, usr => $username, members => \@members,
        groupname => $param->{groupname},
        machine => \@machine, datasets => \@datasets,
        err => $err, myrole => $id2role{$myrole}, err2 => $err2, err3 => $err3,
        job => \@job, currentlyvisibility => $currentlyvisibility,
        describe => @org ? $org[0][2] : 'null',
    };
};

get '/organization/:groupname/jobHistory' => sub {
    my $param = params();
    return unless my $username = dashboard::get_username();

    my %group = +{ owner => [], guest => [], master => [], public => [] };
    my $myrole = 0;
    my @o = $dashboard::schedulerDB->selectOrganizationauthByUser( $username );
    #`id`,`name`,`user`,`role`
    map{
        push @{$group{ $_->[2] eq '_public_' ? 'public' : $id2role{$_->[3]}}}, $_->[1];
        $myrole = $_->[3] if ( $_->[2] eq '_public_' || $_->[2] eq $username ) && $param->{groupname} eq $_->[1] && $_->[3] > $myrole;
    }@o;

    return template 'msg', +{ %group, usr => $username, err => 'Permission denied' } unless $myrole;

    my $page = $param->{page};
    $page = 0 unless $page && $page =~ /^\d+$/;
    my $pagesize = 50;

    my @job = $dashboard::schedulerDB->selectJobStopedInfoByGroupPage( $param->{groupname} , $page * $pagesize, $pagesize );
    #`id`,`jobid`,`owner`,`name`,`nice`,`group`,`status`
    template 'organization/jobHistory', +{
        %group, groupname => $param->{groupname}, jobs => \@job,
        page => $page, pagesize => $pagesize,
        usr => $username, joblen => scalar @job,
    };
};

get '/organization/:groupname/submitJob/:name' => sub {
    my $param = params();
    return unless my $username = dashboard::get_username();

    my %group = +{ owner => [], guest => [], master => [], public => [] };
    my $myrole = 0;
    my @o = $dashboard::schedulerDB->selectOrganizationauthByUser( $username );
    #`id`,`name`,`user`,`role`
    map{
        push @{$group{ $_->[2] eq '_public_' ? 'public' : $id2role{$_->[3]}}}, $_->[1];
        $myrole = $_->[3] if ( $_->[2] eq '_public_' || $_->[2] eq $username ) && $param->{groupname} eq $_->[1] && $_->[3] > $myrole;
    }@o;

    return template 'msg', +{ %group, usr => $username, err => 'Permission denied' } unless $myrole;

    my ( $err, $jobid, $uuid, @ip ) = ( '', '' );

    my $ws_url = request->env->{HTTP_HOST};
    $ws_url =~ s/:\d+$//;
    $ws_url .= ":3001";
    $ws_url = "ws://$ws_url/ws";

    $param->{username} = $username;
    if( $param->{cmd} )
    {
        my ( $group, $role, $cmd ) = ( $param->{groupname}, 'slave', $param->{cmd} );
        ( $group, $role, $cmd ) = 
            ( 'antden', 'master', '/opt/AntDen/scripts/install --user :::user::: --host :::host::: --password ":::password:::" --group :::groupname:::  --role :::role:::' )
                if $param->{name} eq 'addMachine';
        ( $group, $role, $cmd ) = 
            ( 'antden', 'master', '/opt/AntDen/antdencli/tools/datasets/create --name :::namex::: --group :::groupname::: --user :::username:::' )
                if $param->{name} eq 'addDatasets';

        my $ip;
        map{
            $ip = $_->[0] if $_->[8] =~ /health=1/ && $_->[7] eq $role
        }$dashboard::schedulerDB->selectMachineInfoByGroup( $group );

        $err = "ip error:$ip" unless $ip && $ip =~ /^\d+\.\d+\.\d+\.\d+$/;
        $err = "group error:$group" unless $group && $group =~ /^[a-z0-9_\.\-]+$/;
        #$err = "cmd err:$cmd" unless $cmd && $cmd =~ /^[\/a-zA-Z0-9_:\.\- ]+$/;

        my @arg = $cmd =~ /:::([a-zA-Z0-9]+):::/g;
        map{
            $err = "$_ err" unless defined $param->{$_} && $param->{$_} =~ /^[\.\/a-zA-Z0-9_:%\.\@\(\)\^\-]+$/;
            $cmd =~ s/:::${_}:::/$param->{$_}/g;
        }@arg;

        if( ( @arg == grep{ $param->{$_} }@arg ) && ! $err )
        {
             my $config = [
                 +{
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
                         ip => $ip,
                         resources => [ [ 'CPU', '.', 2 ] ]
                    }
                 } 
             ];

             $jobid = $dashboard::schedulerCtrl->startJob( $config, 5, $group, $username, $param->{name} );
             $uuid = $jobid. ".001_$ip.log";
             $uuid =~ s/^J/T/;
        }
    }

    template 'organization/submitJob', +{ %group, groupname => $param->{groupname}, err => $err,
        jobid => $jobid, host => request->{host}, usr => $username,
        tt => "organization/submitJob/" . $param->{name} . ".tt", ws_url => $ws_url, uuid => $uuid };
};

get '/organization/:groupname/changeVisibility' => sub {
    my $param = params();
    return unless my $username = dashboard::get_username();

    my $myrole = 0;
    my $currentlyvisibility = 'private';
    my @members = $dashboard::schedulerDB->selectOrganizationauthByName( $param->{groupname} );
    #`id`,`name`,`user`,`role`
    map{
        $myrole = $_->[3] if ( $_->[2] eq $username ) && $param->{groupname} eq $_->[1] && $_->[3] > $myrole;
    }@members;
    return template 'msg', +{ usr => $username, err => 'Permission denied' } unless $myrole;
    my $err = 'Only owner operation is allowed' unless $myrole >= 3;

    map{ $currentlyvisibility = 'public' if $_->[2] eq '_public_'; }@members;

    if( ! $err && $param->{currentlyvisibility} )
    {
        if( $param->{currentlyvisibility} eq 'public' && $currentlyvisibility ne 'public' )
        {
            $dashboard::schedulerDB->insertOrganizationauth( $param->{groupname} , '_public_' , 1 );
            $currentlyvisibility = 'public';
        }
        if( $param->{currentlyvisibility} eq 'private' && $currentlyvisibility ne 'private' )
        {
            $dashboard::schedulerDB->deleteOrganizationauthByUserAndName( '_public_', $param->{groupname} );
            $currentlyvisibility = 'private'
        }
    }

    my %group = +{ owner => [], guest => [], master => [], public => [] };
    my @o = $dashboard::schedulerDB->selectOrganizationauthByUser( $username );
    #`id`,`name`,`user`,`role`
    map{
        push @{$group{ $_->[2] eq '_public_' ? 'public' : $id2role{$_->[3]}}}, $_->[1];
    }@o;

    template 'organization/changeVisibility', +{
        %group, groupname => $param->{groupname}, err => $err,
        usr => $username, currentlyvisibility => $currentlyvisibility,
    };
};

get '/organization/:groupname/transfer' => sub {
    my $param = params();
    return unless my $username = dashboard::get_username();

    my $myrole = 0;
    my @members = $dashboard::schedulerDB->selectOrganizationauthByName( $param->{groupname} );
    #`id`,`name`,`user`,`role`
    map{
        $myrole = $_->[3] if ( $_->[2] eq $username ) && $param->{groupname} eq $_->[1] && $_->[3] > $myrole;
    }@members;
    return template 'msg', +{ usr => $username, err => 'Permission denied' } unless $myrole;
    my $err = 'Only owner operation is allowed' unless $myrole >= 3;

    if( ! $err && $param->{user} )
    {
        $dashboard::schedulerDB->deleteOrganizationauthByUserAndName( $param->{user}, $param->{groupname} );
        $dashboard::schedulerDB->insertOrganizationauth( $param->{groupname} , $param->{user} , 3 );
        $dashboard::schedulerDB->deleteOrganizationauthByUserAndName( $username, $param->{groupname} );
    }

    my %group = +{ owner => [], guest => [], master => [], public => [] };
    my @o = $dashboard::schedulerDB->selectOrganizationauthByUser( $username );
    #`id`,`name`,`user`,`role`
    map{
        push @{$group{ $_->[2] eq '_public_' ? 'public' : $id2role{$_->[3]}}}, $_->[1];
    }@o;

    template 'organization/transfer', +{
        %group, groupname => $param->{groupname}, members => [ map{ $_->[2] }@members ],
        usr => $username, err => $err,
    };
};

get '/organization/:groupname/delete' => sub {
    my $param = params();
    return unless my $username = dashboard::get_username();

    my $myrole = 0;
    my @members = $dashboard::schedulerDB->selectOrganizationauthByName( $param->{groupname} );
    #`id`,`name`,`user`,`role`
    map{
        $myrole = $_->[3] if ( $_->[2] eq $username ) && $param->{groupname} eq $_->[1] && $_->[3] > $myrole;
    }@members;
    return template 'msg', +{ usr => $username, err => 'Permission denied' } unless $myrole;
    my $err = 'Only owner operation is allowed' unless $myrole >= 3;

    if( ! $err && $param->{delete} )
    {
        $dashboard::schedulerDB->deleteOrganizationauthByName( $param->{groupname} );
    }

    my %group = +{ owner => [], guest => [], master => [], public => [] };
    my @o = $dashboard::schedulerDB->selectOrganizationauthByUser( $username );
    #`id`,`name`,`user`,`role`
    map{
        push @{$group{ $_->[2] eq '_public_' ? 'public' : $id2role{$_->[3]}}}, $_->[1];
    }@o;

    template 'organization/delete', +{
        %group, groupname => $param->{groupname},
        usr => $username, err => $err,
    };
};

get '/organization/:groupname/leave' => sub {
    my $param = params();
    return unless my $username = dashboard::get_username();

    my $myrole = 0;
    my @members = $dashboard::schedulerDB->selectOrganizationauthByName( $param->{groupname} );
    #`id`,`name`,`user`,`role`
    map{
        $myrole = $_->[3] if ( $_->[2] eq $username ) && $param->{groupname} eq $_->[1] && $_->[3] > $myrole;
    }@members;
    return template 'msg', +{ usr => $username, err => 'Permission denied' } unless $myrole;
    my $err = 'The owner is not allowed to leave the organization. You can choose to delete or transfer the organization to another user.' if $myrole >= 3;

    if( ! $err && $param->{leave} )
    {
        $dashboard::schedulerDB->deleteOrganizationauthByUserAndName( $username, $param->{groupname} );
    }

    my %group = +{ owner => [], guest => [], master => [], public => [] };
    my @o = $dashboard::schedulerDB->selectOrganizationauthByUser( $username );
    #`id`,`name`,`user`,`role`
    map{
        push @{$group{ $_->[2] eq '_public_' ? 'public' : $id2role{$_->[3]}}}, $_->[1];
    }@o;

    template 'organization/leave', +{
        %group, groupname => $param->{groupname},
        usr => $username, err => $err,
    };
};

true;
