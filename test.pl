BEGIN
{ 
   use Test::More tests => 9;
   use_ok(CGI::Gzip);
}

use strict;
use warnings;

use Carp;
$SIG{__WARN__} = \&Carp::confess;
$SIG{__DIE__} = \&Carp::confess;

my $compare = "Hello World!\n";  # expected output

# Get CGI header for comparison
my $compareheader = CGI->new("")->header();


eval "use IO::String";
my $hasIO = $@ ? 0 : 1;
eval "use IO::Zlib; use Compress::Zlib";
my $hasZlib = $@ ? 0 : 1;

# Have to use a temp file since Compress::Zlib doesn't like IO::String
my $testfile = "temp.test";

# Turn off compression
ok(CGI::Gzip->useCompression(0), "Turn off compression");

# First, some Zlib tests

my $zcompare = Compress::Zlib::memGzip($compare);
my $testbuf = $zcompare;
$testbuf = Compress::Zlib::memGunzip($testbuf);
is ($testbuf, $compare, "Compress::Zlib double-check");
{
   open FILE, ">$testfile" or die "Can't write a temp file";
   select FILE;
   my $fh = IO::Zlib->new(eval "\\*".select, "wb");
   select $fh;
   print $compare;
   close $fh;
   close FILE;
   select STDOUT;

   open FILE, "<$testfile" or die "Can't read temp file";
   my $out = join("", <FILE>);
   close(FILE);
   is($out, $zcompare, "IO::Zlib test");
}

# no compression

SKIP: {
   my $tests = 2;
   skip "IO::String module is not installed", $tests if (!$hasIO);

   my $cgi = CGI::Gzip->new("");
   ok($cgi, "Constructor");

   my $out;
   my $fh = IO::String->new($out);
   select $fh;
   print $cgi->header();
   print $compare;
   $fh->close();
   select STDOUT;
   is($out, $compareheader.$compare, "CGI template");
}

# CGI and compression


SKIP: {
   my $tests = 3;
   skip "IO::String module is not installed", $tests if (!$hasIO);
   skip "IO::Zlib module is not installed", $tests if (!$hasZlib);

   # Turn on compression
   ok(CGI::Gzip->useCompression(1), "Turn on compression");

   $ENV{HTTP_ACCEPT_ENCODING} = "gzip";

   my $out;
   open FILE, ">$testfile" or die "Can't write a temp file";
   select FILE;
   {
      # Wrap in a block so the $cgi destructor is called
      my $cgi = CGI::Gzip->new("");
      print $cgi->header();
      print $compare;
   }
   close(FILE);
   select STDOUT;

   open FILE, "<$testfile" or die "Can't read temp file";
   $out = join("", <FILE>);
   close(FILE);
   ok($out =~ s/^Content-Encoding: gzip\n//s || $out =~ s/^(Content-Encoding:\s*)gzip, /$1/m, "Gzipped CGI template (header encoding text)");
   is($out, $compareheader.$zcompare, "Gzipped CGI template (body test)");
}

unlink($testfile);
