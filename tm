#!/usr/bin/perl
use strict;
use warnings;
use Data::Dumper;
use IO::File;
use Getopt::Long;

my $DEBUG;
our %ENV;

my $PROG=$0; $PROG =~ s{.*/}{};
my $LOGDIR="$ENV{HOME}/logs";
my $LOGNAME="${PROG}.log";
my $LOGFILE="$LOGDIR/$LOGNAME";
my $DEFAULT_TITLE="Desktop";
my @DEFAULT_CMD=("bash");
our ($TITLE, $ACTION, $CFLAG);
our $PBS="bottom";

our $OLDPATH=$ENV{PATH};
$ENV{PATH}="/bin:/usr/bin";
umask 0011;
our $TTY= -t STDIN ? `tty` : ""; chomp $TTY;
our %INFO;

sub log_it(@);
sub set_err($;@);
sub get_pane_info(;@);
sub get_active_panel();
sub set_title(;$$$);
sub update_pane_info();
sub rename_window();

sub set_err($;@) {
  my $f=shift;
  $@=sprintf($f,@_);
  chomp $@;
  return;
}

sub log_it(@) {
  my ($f, @a);
  if(@_ == 1) {
    $f="%s";
    @a=@_;
  } else {
    ($f, @a) = @_;
  }
  my $message=sprintf($f, @a);
  chomp $message;
  if(0) {
    my $pmessage=$message;
    $pmessage =~ s/\n/\n==== /g;
    print ">>> $pmessage\n";
  }
  if(open(my $fh, ">>", $LOGFILE)) {
    my $now=scalar(gmtime(time));
    for my $line (split "\n", $message) {
      printf $fh "%s (%d): %s\n", $now, $$, $line;
    }
    close $fh;
  } else {
    print "<><> $!\n";
  }
}
sub debug(@) { return unless $DEBUG; log_it(@_); };

sub system2(;@) {
  my $fh;
  my $pid=open($fh, "-|");
  die "Fork failed\n" unless defined $pid;
  unless($pid) {
    close STDERR;
    open STDERR, ">&", \*STDOUT;
    STDOUT->autoflush();
    STDERR->autoflush();
    exec @_;
    die "Exec falied: $!\n";
  }
  my @output=(<$fh>);
  close $fh;
  return @output;
}


sub nsort(@) {
  my ($x, $y);
  return sort {
      $x=$a;
      $y=$b;
      ($x) = $x =~ /(\d+)/;
      ($y) = $y =~ /(\d+)/;
      return ($x//0) <=> ($y//0);
  } @_;
}

sub get_pane_info(;@) {
  my %ignore=map { ($_, 1) } @_;
  my %info;
  local $_;
  log_it "Getting active panes";
  map {
    chomp;
    my ($tty, $w_id, $p_id, $p_bs, $p_title) = split (/\s+/, $_, 7);
    if($tty =~ m{^/dev/pts/\d+$}) {
      log_it " pane %s%s on %s", $w_id, $p_id, $tty;
      $info{by_tty}{$tty}={
        tty     =>  $tty,
        w_id    =>  $w_id,
        p_id    =>  $p_id,
        p_bs    =>  $p_bs,
        p_title =>  $p_title,
        p_name  =>  undef,
        t_id    =>  undef,
      } unless $ignore{$tty};
    }
  } system2("tmux", "list-panes", "-a", "-F", "#{pane_tty} #I #D #{pane-border-status} #{pane_title}");

  log_it "Getting pane t_id list";
  my %dups=(count=>{}, caught=>{});
  map {
    chomp;
    if(     /^([^=]+)=(\d+):(.*)$/
        and exists($info{by_tty}{$1})) {
      log_it " $_";
      if(++$dups{count}{$2} > 1) {
        log_it " duplicate id $2 on $1 - will reasign";
        $dups{caught}{$1}=$3;
      } else {
        $info{by_tty}{$1}{t_id}=$2;
        $info{by_tty}{$1}{p_name}=$3;
      }
    }
  } nsort system2("tmux", "showenv", "-g");
  #log_it Dumper(\%dups);
  my $new_t_id=0;
  map {
    while($dups{count}{$new_t_id}) { $new_t_id++; }
    log_it "Reasigning $_ to new tid $new_t_id";
    my $p_name=$dups{caught}{$_};
    $info{by_tty}{$_}{t_id}=$new_t_id;
    $info{by_tty}{$_}{p_name}=$p_name;
    system2("tmux", "setenv", "-g", $_, "$new_t_id:$p_name");
    $new_t_id++;
  } nsort keys %{ $dups{caught} };
  map {
    #log_it '$_ %s', defined($_) ? ref($_)//"scalar" : "<undef>";
    if(defined($_->{t_id})) {
      $info{by_w_id}{$_->{w_id}}{$_->{t_id}}=$_;
      $info{by_t_id}{$_->{t_id}}=$_;
    }
  } values %{ $info{by_tty} };
  my $next_id=0;
  while($info{by_t_id}{$next_id}) { $next_id++; }
  $info{next_id}=$next_id;
  $info{my_id}=exists($info{by_tty}{$TTY}{t_id})
    ? $info{by_tty}{$TTY}{t_id}//$next_id
    : $next_id;
  #log_it Dumper(\%info);
  return %info;
}

sub get_active_panel() {
  my @cmd=("tmux", "setenv", "-F", "active_window", " #I #D", ";", "showenv", "active_window");
  log_it "Running: %s\n", join(" ", @cmd);
  my ($n, $w, $p) = split /\s+/, join("", system2(@cmd));
  return $w//"", $p//"";
}

sub set_title(;$$$) {
  my ($p_name, $t_id, $get_wid) = @_;
  $p_name=$p_name//$TITLE;
  $t_id=$t_id//$INFO{my_id};
  unless(defined($p_name)) { return set_err "Missing name"; }
  unless(defined($t_id))  { return set_err "Missing t_id"; }
  my @WID;
  my $tty=$TTY;
  if($get_wid) {
    log_it "Finding w_id for t_id %s", $t_id;
    #log_it Dumper($INFO{by_t_id}{$t_id});
    my $w_id=$INFO{by_t_id}{$t_id}{w_id};
    return set_err "Cannot find w_id" unless defined $w_id;
    my $p_id=$INFO{by_t_id}{$t_id}{p_id};
    return set_err "Cannot find p_id" unless defined $p_id;
    push @WID, "-t", "${w_id}.${p_id}";
    $tty=$INFO{by_t_id}{$t_id}{tty};
    return set_err "Cannot find tty" unless defined $p_id;
  }


  log_it "p_name %s", $p_name//"<unset>";
  log_it "t_id %s", $t_id//"<unset>";
  my $p_title="($t_id) $p_name";

  my  @cmd=("tmux", "setenv", "-g", $tty, "$t_id:$p_name");
  log_it "Running: %s\n", join(" ", @cmd);
  system2(@cmd);


  #my ($a_w_id, $a_p_id) = get_active_panel();
  #my @rcmd=("tmux", "select-window", "-t", $a_w_id, ";", "select-pane", "-t", $a_p_id);


  @cmd=("tmux", "select-pane", "-T", $p_title, @WID);
  log_it "Running: %s\n", join(" ", @cmd);
  system2(@cmd);

  #log_it "Running: %s\n", join(" ", @rcmd);
  #system2(@rcmd);

  $INFO{by_tty}{$tty}{p_name}=$p_name;
  $INFO{by_tty}{$tty}{p_title}=$p_title;
  return 1;
}


sub update_pane_info() {
  local $_;
  %INFO=get_pane_info();
  our ($my_w_id, $my_p_id);
  if(exists($INFO{by_tty}{$TTY})) {
    $my_w_id=$INFO{by_tty}{$TTY}{w_id};
    $my_p_id=$INFO{by_tty}{$TTY}{p_id};
  }
  log_it "checking for bad ids and titles\n";
  my @ttys=keys %{ $INFO{by_tty}};
  log_it "Checking ttys: \n  '%s'\n", join("'\n  '", @ttys); 
  my @scmd;
  for my $tty(@ttys) {
    next unless $tty =~ m{^/dev/pts/\d+$};
    my $data=$INFO{by_tty}{$tty};
    if(defined($data->{t_id})) {
      log_it "$tty has id $data->{t_id}\n";
      my $w_p_title = sprintf "(%d) %s", $data->{t_id}, $data->{p_name};
      if($w_p_title eq $data->{p_title}) {
        log_it "id %s has expected pane title '%s'", $data->{t_id}, $w_p_title;
      } else {
        log_it "Updating pane title for %s '%s'->'%s'\n", $tty, $data->{p_title}, $w_p_title;
        set_title($data->{p_name}, $data->{t_id}, 1) or log_it "Set_title: %s", $@;
      }
    } else {
      my $nid;
      log_it "Updating missing tid on $tty\n";
      my $p_name=$data->{p_name};
      unless($p_name) {
        system2("tmux", "setenv", "-g", "-F", "p_$tty", "#{pane_title}");
        my @out=system2("tmux", "showenv", "-g", "p_$tty");
        $p_name="A Window";
        local $_;
        for (@out) {
          chomp;
          log_it $_;
          if(/^[^=]*=(?:\((\d+)\)\s+)?(.*)/) {
            $nid=$1;
            $p_name=$2;
            log_it "Found existing t_id %s title %s", $nid//"<unset>", $p_name//"<unset>";
            last;
          }
        }
      }
      if(defined($nid) and $nid =~ /^\d+$/ and !$INFO{by_t_id}{$nid}) {
        log_it "Reusing t_id $nid from pane_title\n";
      } else {
        $nid=0; while($INFO{by_t_id}{$nid}) { $nid++; };
      }
      $INFO{by_t_id}{$nid}=$data;
      $data->{t_id}=$nid;
      #$data->{p_name}=$data->{p_title}//"Unknown Window";
      set_title($p_name, $nid, 1) or log_it "Set_title: %s", $@;
    }
  }
  log_it "checking window names and ordering";
  %INFO=get_pane_info();
  my %WINFO;

  for (system2 "tmux", "list-windows", "-F", "#I #W") {
    chomp;
    my ($w_id, $w_name) = split(/\s+/, $_, 2);
    my $data=$INFO{by_w_id}{$w_id} or next;
    my $ent= {
      w_id    => $w_id,
      w_name  => $w_name,
    };
    $ent->{t_id_list} = [ sort { $a <=> $b } keys %{$INFO{by_w_id}{$w_id} } ];
    $ent->{w_w_id} = $ent->{t_id_list}[0];
    $ent->{t_id}=$ent->{t_id_list}[0];

    $WINFO{$w_id}=$ent;
  }
  my @entlist=values(%WINFO);
  for my $ent (@entlist) {
    my $w_p_bs = @{$ent->{t_id_list}}>1 ? $PBS : "off";
    for my $p (values %{$INFO{by_w_id}{$ent->{w_id}}}) {
      if( $p->{p_bs} ne $w_p_bs) {
        log_it "Updating panel border status for $p->{w_id}.$p->{p_id}";
        system2("tmux", "set", "-t", "$p->{w_id}.$p->{p_id}", "-F", "pane-border-status", "#{?#{>:#{window_panes},1},$PBS,off}");
      }
    }
    log_it "*** Checking ent $ent->{w_id} ***"; 
    if($ent->{w_id} eq $ent->{w_w_id}) {
      log_it "t_id %s has w_id '%s' -ok", $ent->{t_id}, $ent->{w_w_id};
    } else {
      log_it "t_id %s has w_id '%s' - expected '%s'", $ent->{t_id}, $ent->{w_id}, $ent->{w_w_id};
      my $old=$ent->{w_id};
      my $new=$ent->{w_w_id};
      my ($swap, $tmp_id, $tmp_ent);
      my ($a_w_id, $a_p_id) = get_active_panel();
      my @cmd;
      if($WINFO{$new}) {
        $swap=1;
        $tmp_id=$new;
        $tmp_ent=$WINFO{$new};
        my $s=$old;
        my $t=$new;
        my @DOPT=("-d");
        if($a_w_id eq $old) {
          log_it "Active is src";
          #$s=$old;
          #$t=$new;
          #@DOPT=("-d");
        } elsif($a_w_id eq $new) {
          $s=$new;
          $t=$old;
          #@DOPT=("-d");
          log_it "Active is dst";
        } else {
          #$s=$old;
          #$t=$new;
          #@DOPT=("-d");
          log_it "Active not in swap";
        }
        log_it "swapping w_id's %s and %s", $s, $t;
        @cmd=("tmux", "swap-window", @DOPT, "-s", $s, "-t", $t);
      } else {
        my @DOPT;
        log_it "moving w_id %s -> %s", $old, $new;
        if($a_w_id eq $old) {
          log_it "Moving active window";
          @DOPT=();
        } else {
          log_it "Moving inactive window";
          @DOPT=("-d");
        }
        @cmd=("tmux", "move-window", @DOPT, "-s", $old, "-t", $new);
      }
      #sleep 2;
      log_it "********************************************";
      log_it "Running: %s\n", join(" ", @cmd);
      system(@cmd) and last;
      log_it "updating current ent to w_id $new";
      $ent->{w_id}=$new;
      log_it "updating WID-$new to current ent";
      $WINFO{$new}=$ent;
      if($swap) {
        log_it "Updating other ent to w_id $old";
        $tmp_ent->{w_id}=$old;
        log_it "updating WID-$old to other ent";
        $WINFO{$old}=$tmp_ent;
        log_it Dumper $tmp_ent;
      } else {
        log_it "Removing WID-$old";
        delete($WINFO{$old});
      }
    }
    if(@{$ent->{t_id_list}} > 1) {
      $ent->{w_w_name}=sprintf "Windows %s ", join(",", @{$ent->{t_id_list}});
    } else {
      $ent->{w_w_name}=sprintf "Window %s", $ent->{t_id};
    }
    if($ent->{w_name} ne $ent->{w_w_name}) {
      my @cmd=("tmux", "rename-window", "-t", $ent->{w_id}, $ent->{w_w_name});
      log_it "Updating name for window %s: '%s'->'%s'", $ent->{w_id}, $ent->{w_name}, $ent->{w_w_name};
      log_it "Running: %s\n", join(" ", @cmd);
      system @cmd;
    } else {
      log_it "Window %s has expected name '%s'", $ent->{w_id}, $ent->{w_name};
    }
  }
}

sub rename_window() {
  if(exists($INFO{by_tty}{$TTY})) {
    my $p_name = $INFO{by_tty}{$TTY}{p_name};
    my @cmd=("tmux", "command-prompt",
      "-p" ,"rename-window:",
      "-I", $p_name,
      "run -b 'tm -a set_title -p $TTY -t \"\%\%\"'");
    log_it "Running %s", join(" ", @cmd);
    system(@cmd);
    log_it "Command completed (%s)", $?;
  }
}

die "Not in tmux\n" unless $ENV{TMUX};

Getopt::Long::Configure("pass_through");
if($PROG =~ /^(.*)refresh$/) {
  $ACTION="refresh";
  $PROG=$1;
  $LOGNAME="${PROG}.log";
  $LOGFILE="$LOGDIR/$LOGNAME";
} else {
  GetOptions(
    "title=s"   => \$TITLE,
    "action=s"  => \$ACTION,
    "pty=s"     => \$TTY,
  );
}

mkdir $LOGDIR;
log_it "\n$PROG called with title '%s', action '%s', cflag '%s', %d args '%s'",
   $TITLE//"<unset>", $ACTION//"<unset>", $CFLAG//0, scalar(@ARGV), join("', '", @ARGV);

$ACTION=$ACTION//"run";
$ACTION =~ s/-/_/g;

%INFO=get_pane_info();

if($ACTION eq "set_title") {
  set_title or log_it "Set_title: %s", $@;
} elsif($ACTION eq "select_window") {
  if(@ARGV) {
    my $target=$ARGV[0];
    my $w_id;
    my $p_id;
    if(exists $INFO{by_t_id}{$target}) {
      log_it "ONE";
      $w_id=$INFO{by_t_id}{$ARGV[0]}{w_id};
      $p_id=$INFO{by_t_id}{$ARGV[0]}{p_id};
    } elsif($target =~ /^(?:[^:]*:)?(\d+)(?:\.(\d+))?/) {
      $w_id=$1;
      $p_id=$2 if $2;
    }
    if(defined($w_id)) {
      my @cmd=("tmux", "select-window", "-t", $w_id);
      if(defined($p_id)) {
        push @cmd, ";", "select-pane", "-t", $p_id;
      }
      log_it "Running %s", join(" ", @cmd);
      system2(@cmd);
    }
  } else {
    printf "Window '%s' is in hiding\n", $ARGV[0];
  }
} elsif($ACTION eq "rename_window") {
    rename_window();
} elsif($ACTION eq "refresh") {
  #sleep 2;
  update_pane_info();
} elsif($ACTION eq "run") {
  if(@ARGV) {
    if( $ARGV[0] eq "-c") {
      $TITLE=$TITLE//$ARGV[1]//"sh";
      @ARGV=("/bin/sh", @ARGV);
    } else {
      $TITLE=$TITLE//$ARGV[0];
    }
  } else {
    $TITLE=$TITLE//$DEFAULT_TITLE;
    @ARGV=@DEFAULT_CMD;
  }
  log_it "Setting title to $TITLE";
  set_title() or log_it "Set_title: %s", $@;
  #update_pane_info();
  $ENV{PATH}=$OLDPATH;
  log_it "Running '%s'", join("' '", @ARGV);
  printf "Running: %s\n", join(" ", @ARGV);
  exec @ARGV;
  die "Exec failed: $!\n";
} else {
  log_it"Unknown action: $ACTION";
  die "Unknown action: $ACTION\n";
}
log_it "Done";
exit 0;




