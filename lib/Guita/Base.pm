package Guita::Base;
use prelude;

use Exporter::Lite;

our @EXPORT = qw(route);

use Router::Simple;
use Class::Load qw(load_class);
use Plack::Session;

use Guita::Exception;
use Guita::Request;
use Guita::Response;
use Guita::Views;

use Guita::DataBase;

use Guita::Git;
use DBI;

use Guita::Model::User::Guest;

our $router = Router::Simple->new;

sub throw { my ($self) = shift; Guita::Exception->throw(@_) }
sub route ($$) { $router->connect(shift, { action => shift }) }

sub new {
    my ($class, $env) = @_;
    my $req = Guita::Request->new($env);
    my $res = Guita::Response->new(200);

    bless {
        req => $req,
        res => $res,
    }, $class;
}

sub before_dispatch {
    my ($self) = @_;
    $self->res->header('X-Frame-Options'  => 'DENY');
    $self->res->header('X-XSS-Protection' => '1');


    $self->req->_context($self);
}

sub after_dispatch {
    my ($c) = @_;
}

sub run {
    my ($c) = @_;
    try {
        use Carp; local $SIG{__DIE__} = \&Carp::confess; #XXX
        my ($dest, $route) = $router->routematch($c->req->env);
        if ($dest) {
            my $action = delete $dest->{action};
            $c->req->path_parameters(%$dest);

            $c->before_dispatch;

            if (ref($action) eq 'CODE') {
                $action->(local $_ = $c);
            } else {
                my ($module, $method) = split /\s+/, $action;
                load_class $module; #XXX $module->import;
                $method ||= 'default';
                $module->$method($c);
            }
        } else {
            $c->throw(code => 404, message => 'Action not Found');
        }
    }
    catch {
        if (try { $_->isa('Guita::Exception') }) {
            warn $_->{trace} if GuitaConf('trace_exception');
            $c->res->code($_->{code});
            $c->res->header('X-Message' => $_->{message}) if $_->{message};
            $c->res->header('Location' => $_->{location}) if $_->{location};
            $c->res->content_type('text/plain');
            $c->res->content($_->{message});
        } else {
            die $_;
        }
    }
    finally {
        $c->after_dispatch;
    };

    $c;
}

sub req { $_[0]->{req} }
sub res { $_[0]->{res} }

sub session {
    if (defined $_[0]->{session}) {
        return $_[0]->{session};
    } else {
        return $_[0]->{session} = $_[0]->{req}->env->{'psgix.session'} ? Plack::Session->new($_[0]->{req}->env) : ''
    };
}

### Git

sub git {
    my ($self, $git_dir) = @_;
    Guita::Git->new({git_dir => $git_dir});
}

### DBI

sub db {
    Guita::DataBase->instance;
}

sub dbixl {
    my ($self) = @_;
    $self->db->dbixl;
}

# Connector使うようにする
sub dbh {
    my ($self, $name) = @_;
    $self->{_dbh}->{$name} ||= do {
        my $dsn = GuitaConf("dsn_$name") or croak "Unknwon DSN: $name";
        my $dsa = [ DBI->parse_dsn($dsn) ];

        my $dbh = DBI->connect($dsn, 'nobody', 'nobody', {
            RaiseError => 1,
            Callbacks => {
                connected => sub {
                    shift->do("SET NAMES utf8");
                    return;
                }
            }
        });
        $dbh;
    };
}

sub user {
    my ($self) = @_;

    $self->{_user} ||= do {
        my $sk = $self->req->cookies->{csk};
        my $user = $sk && $self->dbixl->table('user')->search({ sk => $sk })->single;
        $user || Guita::Model::User::Guest->new;
    };
}

sub id {
    my ($self) = @_;
    scalar $self->req->param('id');
}

sub sha {
    my ($self) = @_;
    scalar $self->req->param('sha');
}

sub filename {
    my ($self) = @_;
    scalar $self->req->param('filename');
}

sub username {
    my ($self) = @_;
    scalar $self->req->param('username');
}

1;

__END__
