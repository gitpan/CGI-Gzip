package CGI::Gzip;

=head1 NAME

CGI::Gzip - CGI with automatically compressed output

=head1 SYNOPSIS

  use CGI::Gzip;

  my $cgi = new CGI::Gzip;
  print $cgi->header();
  print "<html> ...";

=head1 DESCRIPTION

CGI::Gzip extends the CGI class to auto-detect whether the client
browser wants compressed output and, if so and if the script chooses
HTML output, apply gzip compression on any output.  This module is
intended to be a drop-in replacement for CGI.pm in a typical scripting
environment.

Apache mod_perl users may wish to consider the Apache::Compress or
Apache::GzipChain modules, which allow more transparent output
compression than this module can provide.

=head2 Headers

At the time that a header is requested, CGI::Gzip checks the
HTTP_ACCEPT_ENCODING environment variable (passed by Apache).  If this
variable includes the flag "gzip" and the mime-type is "text/html",
then gzipped output is prefered.  The header is altered to add the
"Content-Encoding: gzip" flag compression is turned on.

Naturally, it is crucial that the CGI application output nothing
before the header is printed.  If this is violated, things will go
badly.

=head2 Compression

When the header is created, this module sets up a new filehandle to
accept data.  The Perl select() function is used to direct all print()
calls which lacka filehandle argument (i.e. those which would normally
go to STDOUT) to this filehandle.  The new filehandle passes data
verbatim until it detects the end of the CGI header.  At that time, it
switches over to Gzip output for the remainder of the CGI run.

=cut

require 5.005_62;
use strict;
use warnings;
use Carp;
use CGI;

our @ISA = qw(CGI);
our $VERSION = '0.01';

# Package globals

my $global_use_compression = 1; # user-settable
my $global_can_compress = undef; # 1 = yes, 0 = no, undef = don't know yet

#==============================

=head1 CLASS METHODS

=over 4

=cut

#==============================

=item new <CGI-ARGS>

Create a new object.  This resets the environment before creating a
CGI.pm object.  This should not be called more than once per script
run!  All arguments are passed to the parent class.

=cut

sub new
{
   my $pkg = shift;

   if ($my::Zlibwrapper::old_fh)
   {
      select $my::Zlibwrapper::old_fh;
      $my::Zlibwrapper::old_fh = undef;
   }
   my $self = $pkg->SUPER::new(@_);
   return $self;
}
#==============================

=item useCompression 1|0

Turn compression on/off for all CGI::Gzip objects.  If
turned on, compression will be used only if the prerequisite
compression libraries are available and if the client browser requests
compression.

=cut

sub useCompression
{
   my $pkg = shift;
   my $set = shift;

   $global_use_compression = $set;
   return $pkg;
}
#==============================

=back

=head1 INSTANCE METHODS

=over 4

=cut

#==============================

=item header HEADER-ARGS

Return a CGI header with the compression flags set properly.  Returns
an empty string is a header has already been printed.

This method engages the Gzip output by fiddling with the default
output filehandle.  All subsequent output via usual Perl print() will
be automatically gzipped except for this header (which must go out as
plain text).

Any arguments will be passed on to CGI::header.  This method should
NOT be called if you don't want your header or STDOUT to be fiddled
with.

=cut

sub header
{
   my $self = shift;
   # further args passed on below

   if ($self->{'.header_printed'} && $self->{'.zlib_fh'})
   {
      return tied(${$self->{'.zlib_fh'}})->{pending_header};
   }

   my $header = $self->SUPER::header(@_);
   $self->_startCompression(\$header);
   return $header;
}
#==============================

# Enable the compression filehandle if:
#  - The output is text/html
#  - The programmer wants compression, indicated by the useCompression()
#    method
#  - Client wants compression, indicated by the Accepted-Encoding HTTP field
#  - The IO::Zlib compression library is available

sub _startCompression
{
   my $self = shift;
   my $R_header = shift;  # Passed by reference so we can change it

   my $compress = 1;

   # Check programmer preference
   $compress = $global_use_compression;

   # Check that the output will be HTML
   $compress &&= $$R_header =~ /^Content-Type:.*\btext\/html\b/m;

   # Check that browser supports gzip
   my $acc = $ENV{HTTP_ACCEPT_ENCODING};
   $compress &&= ($acc && $acc =~ /\bgzip\b/);

   # Check that IO::Zlib is available
   if ($compress)
   {
      if (!defined $global_can_compress)
      {
         local $SIG{__WARN__} = 'DEFAULT';
         eval "require IO::Zlib";
         $global_can_compress = $@ ? 0 : 1;
      }
      $compress &&= $global_can_compress;
   }

   if ($compress)
   {
      # Success!!  Set up the compressed output stream

      my $oldfh = $my::Zlibwrapper::old_fh = select();
      if (!ref($oldfh))
      {
         $oldfh = eval "\\*".$my::Zlibwrapper::old_fh;
      }

      my $filehandle = my::Zlibwrapper->new($oldfh, "wb");
      if (!$filehandle)
      {
         carp "Failed to open Zlib output, reverting to uncompressed output";
         return undef;
      }

      # All output from here on goes to our new filehandle
      select $filehandle;
      $self->{'.zlib_fh'} = $filehandle;  # needed for destructor

      # Stick the encoding message into the header.  Be sure not to
      # overwrite an existing encoding message.
      if ($$R_header !~ /^Content-Encoding:.*\bgzip\b/mi)
      {
         $$R_header =~ s/^(?:Content-Encoding:\s*)/gzip, /mio or
             $$R_header = "Content-Encoding: gzip\n" . $$R_header;
      }
      tied(${$self->{'.zlib_fh'}})->{pending_header} = $$R_header;
   }

   return $self;
}
#==============================

=item DESTROY

Override the CGI destructor so we can close the Gzip output stream, if
there is one open.

=cut

sub DESTROY
{
   my $self = shift;

   if ($self->{'.zlib_fh'})
   {
      $self->{'.zlib_fh'}->close() 
          or &croak("Failed to close the Zlib filehandle");
   }
   return $self->SUPER::DESTROY();
}
#==============================

package my::Zlibwrapper;

=back

=head1 HELPER CLASS

CGI::Gzip also implements a helper class in package my::Zlibwrapper
which subclasses IO::Zlib.  This helper is needed to make sure that
output is not compressed util the CGI header is emitted.  This
wrappers delays the ignition of the zlib filter until it sees the
exact same header generated by CGI::Gzip::header() pass through it's
WRITE() method.  If you change the header before printing it, this
class will throw an exception.

This class hold one global variable representing the previous default
filehandle used before the gzip filter is put in place.  This
filehandle, usually STDOUT, is replaced after the gzip stream finishes
(which is usually when the CGI object goes out of scope and is
destroyed).

=cut

our @ISA = qw(IO::Zlib);

our $old_fh = undef; # storage in the case of persistent scripts
                           # (mod_perl, etc)

sub OPEN
{
   my $self = shift;

   # Delay opening until after the header is printed.
   $self->{openargs} = [@_];
   return $self;
}

sub WRITE
{
   my $self = shift;
   my $buf = shift;
   my $length = shift;
   my $offset = shift;

   # Appropriated from IO::Zlib:
   &Carp::croak("bad LENGTH") unless ($length <= length($buf));
   &Carp::croak("OFFSET not supported") if (defined($offset) && $offset != 0);

   my $bytes = 0;
   my $header = $self->{pending_header};
   if ($header)
   {
      if (length($header) > $length)
      {
         $self->{pending_header} = substr($header, $length);
         $header = substr($header, 0, $length);
      }
      else
      {
         $self->{pending_header} = "";
      }
      if ($buf =~ s/^\Q$header//s)
      {
         my $fh = $old_fh || \*STDOUT;
         no strict qw(refs);
         if (print $fh $header)
         {
            $bytes += length($header);
            $length -= length($header);
         }
         else
         {
            &Carp::croak("Failed to print the uncompressed CGI header");
         }
         if (!$self->{pending_header})
         {
            # Finished printing header!
            # Complete delayed open
            if (!$self->SUPER::OPEN(@{$self->{openargs}}))
            {
               &Carp::croak("Failed to open the compressed output stream");
            }
         }
      }
      else
      {
         &Carp::croak("Expected to print the CGI header");
      }
   }
   if ($length)
   {
      $bytes += $self->SUPER::WRITE($buf, $length, $offset);
   }
   return $bytes;
}

sub CLOSE
{
   my $self = shift;

   if ($old_fh)
   {
      select $old_fh;
      $old_fh = undef;
   }
   return $self->SUPER::CLOSE();
}

1;
__END__

=head1 TO DO

* Improve the header mangling code

* Test in mod_perl or FastCGI environments

* Clean up the filehandle manipulation in _startCompression() since
the effects of my experimentation are still apparent.

* Test under Perl versions earlier than 5.8.0

* Handle errors more gracefully in WRITE()

=head1 SEE ALSO

CGI::Gzip depends on CGI and IO::Zlib.  Related functionality is
available from Apache::Compress or Apache::GzipChain.

=head1 AUTHOR

Chris Dolan, Clotho Advanced Media, I<chris@clotho.com>

=head1 LICENSE

GPL v2, see the COPYING file in this distribution.

=cut
