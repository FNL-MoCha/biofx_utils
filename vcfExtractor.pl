#!/usr/bin/perl
# Script to pull out column information from a VCF file.  Can also grab variant information
# based on a position lookup using the '-p' option.  
#
# Need to make sure to install the latest version of VCF Tools to avoid generic Perl error 
# message in output.  Can build from source, or I built a .deb file to installed it on 
# Debian systems.
#
# D Sims 2/21/2013
#################################################################################################
use warnings;
use strict;
use autodie;

use Getopt::Long qw(:config bundling auto_abbrev no_ignore_case );
use List::Util qw{ sum min max };
use Sort::Versions;
use JSON::XS; 
use Data::Dump;
use Term::ANSIColor;

( my $scriptname = $0 ) =~ s/^(.*\/)+//;
my $version = "v3.9.14_110314";
my $description = <<"EOT";
Program to extract fields from an Ion Torrent VCF file generated by TVCv4.0+.  By default the program 
will extract the following fields:

     CHROM:POS REF ALT Filter Filter_Reason VAF TotCov RefCov AltCov COSID

This can only be modified currently by the hardcoded variable '\$vcfFormat'.

This version of the program also supports extracting only variants that match a position query based
on using the following string: chr#:position. Additionally, Hotspot annotated variants (i.e. those
variants that have a COSMIC, OM, or other annotation in the TVC output), can be searched using the
Hotspot ID (e.g. COSM476).  

Multiple positions can be searched by listed each separated by a space and wrapping the whole query in
quotes:

        vcfExtractor -p "chr17:29553485 chr17:29652976" <vcf_file>

For batch processing, a lookup file with the positions (one on each line in the same format as
above) can be passed with the '-f' option to the script:

        vcfExtractor -l lookup_file <vcf_file>
EOT

my $usage = <<"EOT";
USAGE: $scriptname [options] [-f {1,2,3}] <input_vcf_file>

    Program Options
    -o, --output    Send output to custom file.  Default is STDOUT.
    -t, --tvc32     Run the script using the TVCv3.2 VCF files.  Will be deprecated once TVCv4.0 fully
                    implemented
    -O, --OVAT      Add Oncomine OVAT annotation information to output if available.
    -v, --version   Version information
    -h, --help      Print this help information

    Filter and Output Options
    -p, --pos       Output only variants at this position.  Format is "chr<x>:######" 
    -c, --cosid     Look for variant with matching COSMIC ID (or other Hotspot ID)
    -l, --lookup    Read a list of variants from a file to query the VCF. 
    -f, --fuzzy     Less precise (fuzzy) position match. Strip off n digits from the position string.
                    MUST be used with a query option (e.g. -p, -c, -l), and can not trim more than 3 
                    digits from string.
    -n, --noref     Output reference calls.  Ref calls filtered out by default
    -N, --NOCALL    Remove 'NOCALL' entries from output
    -a, --annot     Only report Oncomine Annotated Variants
EOT

my $help;
my $ver_info;
my $outfile;
my $positions;
my $lookup;
my $fuzzy;
my $noref;
my $tvc32;
my $nocall;
my $hsids;
my $ovat;
my $ovat_filter;

GetOptions( "output|o=s"    => \$outfile,
            "annot|a"       => \$ovat_filter,
            "OVAT|O"        => \$ovat,
            "cosid|c=s"     => \$hsids,
            "NOCALL|N"      => \$nocall,
            "pos|p=s"       => \$positions,
            "tvc32|t"       => \$tvc32,
            "lookup|l=s"    => \$lookup,
            "fuzzy|f=i"     => \$fuzzy,
            "noref|n"       => \$noref,
            "version|v"     => \$ver_info,
            "help|h"        => \$help )
        or die "\n$usage";

sub help {
	printf "%s - %s\n\n%s\n\n%s\n", $scriptname, $version, $description, $usage;
	exit;
}

sub version {
	printf "%s - %s\n", $scriptname, $version;
	exit;
}

help if $help;
version if $ver_info;

# Set up some colored output flags
my $warn = colored( "WARN:", 'bold yellow on_black');
my $err =  colored( "ERROR:", 'bold red on_black');
my $info = colored( "INFO:", 'bold cyan on_black');
my $on = colored( "On", 'bold green on_black');
my $off = colored( "Off", 'bold red on_black');

# Double check that fuzzy option is combined intelligently with a position lookup.
if ( $fuzzy ) {
    if ( $fuzzy > 3 ) {
        print "\n$err Can not trim more than 3 digits from the query string.\n\n";
        print $usage;
        exit 1;
    }
    elsif ( $lookup ) {
        print "\n$warn fuzzy lookup in batch mode may produce a lot of results! Continue? ";
        chomp( my $response = <STDIN> );
        exit if ( $response =~ /[(n|no)]/i );
        print "\n";
    }
    elsif ( ! $positions && ! $hsids ) {
        print "$err must include position or hotspot ID query with the '-f' option\n\n";
        print $usage;
        exit 1;
    }
}

# Throw a warning if using the ovat filter without asking for OVAT annotations.
if ( $ovat_filter && ! $ovat ) {
    print "$warn Requested Oncomine annotation filter without adding the OVAT annotations.  Skipping Oncomine filter!\n";
    $ovat_filter = 0;
}

# Make sure enough args passed to script
if ( scalar( @ARGV ) < 1 ) {
    print "$err No VCF file passed to script!\n\n";
    print $usage;
    exit 1;
}

# Parse the lookup file and add variants to the postions list if processing batch-wise
my @valid_hs_ids = qw( BT COSM OM OMINDEL );
if ($lookup) {
    my $query_list = batch_lookup(\$lookup) if $lookup;
    if ( grep { $$query_list =~ /$_\d+/ } @valid_hs_ids ) {
        $hsids = $$query_list;
    } 
    elsif ( $$query_list =~ /chr[0-9YX]+/ ) {
        $positions = $$query_list;
    }
    else {
        print "$err Issue with lookup file.  Check and retry\n"; 
        exit 1;
    }
}

# Double check the query (position / cosid) format is correct
my (@coords, @cosids);
if ( $positions ) {
    print "Checking position id lookup...\n";
    @coords = split( /\s+/, $positions );
    for my $coord ( @coords ) {
        if ( $coord !~ /\Achr[0-9YX]+:\d+$/i ) {
            print "$err '$coord' not valid. Please use the following format for position queries: 'chr#:position'\n";
            exit 1;
        }
    }
} 
elsif ( $hsids ) {
    #print "Checking cosmic id lookup...\n";
    @cosids = split( /\s+/, $hsids );
    for my $varid ( @cosids ) { 
        if ( ! grep { $varid =~ /$_\d+/ } @valid_hs_ids ) {
            print "$err '$varid' is not a valid hotspot query term! Valid lookups are:\n";
            print "\t${_}###\n" for @valid_hs_ids;
            exit;
        }
    }
}

# Write output to either indicated file or STDOUT
my $out_fh;
if ( $outfile ) {
	open( $out_fh, ">", $outfile ) || die "Can't open the output file '$outfile' for writing: $!";
} else {
	$out_fh = \*STDOUT;
}

#########------------------------------ END ARG Parsing ---------------------------------#########

my $inputVCF = shift;

# Check VCF file and options to make sure they're valid
open ( my $vcf_fh, "<", $inputVCF );
my @header = grep { /^#/ } <$vcf_fh>;
if ( $header[0] !~ /VCFv4/ ) {
    print "$err '$inputVCF' does not appear to be a valid VCF file or does not have a header.\n\n";
    print "$usage\n";
    exit 1;
}

# TODO: Still need to refine this
if ( ! $tvc32 && grep { /^##INFO.*Bayesian_Score/ } @header ) {
    print "$warn '$inputVCF' appears to be from TVCv3.2, and the 'tvc32' option was not selected.  The file may not be processed correctly.\n";
    while ( 1 ) {
        print "Continue? [y|n]: ";
        chomp( my $choice = <STDIN> );
        exit 1 if ( $choice =~ /n/i );
        last if ( $choice =~ /y/i );
    }
}

# Trigger OVAT annot capture if available
my $ovat_annot;
( grep { /OncomineVariantAnnotation/ } @header ) ? ($ovat_annot = 1) : ($ovat_annot = 0);
die "$err OVAT output selected, but no OVAT annotations found in VCF file!\n" if ( $ovat && $ovat_annot == 0 ); 
close $vcf_fh;

# FIXME: Allow for running v3.2 VCF files.  Will be removed later.
if ($tvc32) {
    my %vcf32_data = test_32( \$inputVCF );
    ($positions) ? filter_data( \%vcf32_data, \@coords ) : format_output( \%vcf32_data );
    exit;
}

# Get the data from VCF Tools
my $vcfFormat;
if ($ovat_annot) {
    $vcfFormat = "'%CHROM:%POS\t%REF\t%ALT\t%FILTER\t%INFO/FR\t%INFO/OID\t%INFO/OPOS\t%INFO/OREF\t%INFO/OALT\t%INFO/OMAPALT\t%INFO/FUNC\t[%GTR\t%FRO\t%RO\t%FAO\t%AO\t%DP]\n'";
} else {
    $vcfFormat = "'%CHROM:%POS\t%REF\t%ALT\t%FILTER\t%INFO/FR\t%INFO/OID\t%INFO/OPOS\t%INFO/OREF\t%INFO/OALT\t%INFO/OMAPALT\t---\t[%GTR\t%FRO\t%RO\t%FAO\t%AO\t%DP]\n'";
}

my @extracted_data = qx/ vcf-query $inputVCF -f $vcfFormat /;

# Read in the VCF file data and create a hash
my %vcf_data = parse_data( \@extracted_data );

# XXX
my $foo;
($ovat_filter) ? ($foo = "$on!") : ($foo = "$off.");
print "$info OVAT filter status: $foo\n";

# Filter and format extracted data or just format and print it out.
if ( @cosids ) {
    filter_data(\%vcf_data, \@cosids);
}
elsif ( @coords ) {
    filter_data(\%vcf_data, \@coords); 
} 
elsif ( $ovat_filter ) {
    ovat_filter(\%vcf_data);
}
else {
    format_output(\%vcf_data);
}

sub test_32 {
    # FIXME; sub routine to process v3.2 VCF files.  Will go away eventually.
    my $vcf = shift;
    my %parsed_data;

    my $format = "'%CHROM:%POS\t%REF\t%ALT\t%INFO/Bayesian_Score\t[%AD]\n'";
    
    my @data = qx/ vcf-query $$vcf -f $format /;

    for ( @data ) {
        my ( $pos, $ref, $alt, $filter, $cov ) = split;
        my ( $rcov, $acov ) = split( /,/, $cov );
        my $varid = join( ":", $pos, $ref, $alt );

        my $tot_coverage = $rcov + $acov;
        my $vaf = vaf_calc( \$filter, \$tot_coverage, \$rcov, \$acov ); 

        push( @{$parsed_data{$varid}}, $pos, $ref, $alt, $filter, $vaf, $tot_coverage, $rcov, $acov );
    }

    return %parsed_data;
}

sub parse_data {
    # Extract the VCF information and create a hash of the data.  
    my $data = shift;
    my %parsed_data;

    for ( @$data ) {

        my ( $pos, $ref, $alt, $filter, $reason, $oid, $opos, $oref, $oalt, $omapalt, $func, $gtr, $fro, $ro, $fao, $ao, $dp ) = split( /\t/ );

        my ( $ovat_gc, $ovat_vc, $gene_name );
        #print "func  => $func\n";
        #next;

        # FIXME: Getting error when no FUNC block.  Should be skipping over this.  
        ($func eq '.' || $func eq '---') ? next : (($ovat_gc, $ovat_vc, $gene_name) = get_ovat_annot( \$func ) );

        # FIXME: IR generates CNV and Fusion entries that are not compatible.  Skip for now; implement a sub for each later.
        next if ( $alt =~ /[.><\]\d+]/ ); 

        # Clean up filter reason string
        $reason =~ s/^\.,//;

        # Filter out sonw if we don't want to print them later anyway.
        next if $reason eq "NODATA";  # Don't print out NODATA...nothing to learn there.
        $filter = "NOCALL" if ( $gtr =~ m|\./\.| );
        next if ( $nocall && $filter eq "NOCALL" );
        next if ( $noref && $gtr eq '0/0' );

        # Check to see if there is 'F' data or if entry is result of long indel mapper
        if ( $fro eq '.' ) {
            next;
            my $var_id = join( ":", $pos, $ref, $alt );
            my $vaf = vaf_calc( \$filter, \$dp, \$ro, \$ao );
            push( @{$parsed_data{$var_id}}, $pos, $ref, $alt, $filter, $reason, $gtr, $vaf, $dp, $ro, $ao, $oid );
        }
        else {
            # Create some arrays to hold the variant data in case we have MNP calls here
            my @alt_array = split( /,/, $alt );
            my @oid_array = split( /,/, $oid );
            my @opos_array = split( /,/, $opos );
            my @oref_array = split( /,/, $oref );
            my @oalt_array = split( /,/, $oalt );
            my @omapalt_array = split( /,/, $omapalt );
            my @fao_array = split( /,/, $fao );

            # Total coverage better represented by FRO + sum(FAO) than by FDP
            my $tot_coverage = sum( @fao_array ) + $fro;

            my @indices;
            for my $alt_index ( 0..$#alt_array ) {
                my $alt_var = $alt_array[$alt_index];
                my @array_pos = grep { $omapalt_array[$_] eq $alt_var } 0..$#omapalt_array;
                for my $index ( @array_pos ) {
                    (my $parsed_pos = $pos) =~ s/(chr\d+:).*/$1$opos_array[$index]/; 
                    
                    # FIXME: Stupid bug with TVC VCF creation in that a variant can occur in two entries, but only one might have the variant ID listed.  So, 
                    # the information will be lost in the original hash struct.  Add the COSID to the $var_id variable and print both.  Need a more robust way
                    # to deal with this, but at least this will alllow me to search by COSMIC ID for now.
                    my $cosid = $oid_array[$index];
                    my $var_id = join( ":", $parsed_pos, $oref_array[$index], $oalt_array[$index], $cosid ); 
                    #my $var_id = join( ":", $parsed_pos, $oref_array[$index], $oalt_array[$index] ); 
                    my $vaf = vaf_calc( \$filter, \$tot_coverage, \$fro, \$fao_array[$alt_index] );
                    # TODO: Need to make this more robust.  Set up parsing based on GTR field?
                    if ( $vaf ne '.' ) { next if ( $noref && $vaf < 1 ) } # Don't print <1% VAF; new TVC is still showing these entries 
                    if ( $ovat ) {
                        push( @{$parsed_data{$var_id}}, 
                            $parsed_pos, 
                            $oref_array[$index], 
                            $oalt_array[$index], 
                            $filter, 
                            $reason, 
                            $gtr, 
                            $vaf, 
                            $tot_coverage, 
                            $fro, 
                            $fao_array[$alt_index], 
                            $cosid,
                            $gene_name,
                            $ovat_gc,
                            $ovat_vc
                        );
                    } else {
                        push( @{$parsed_data{$var_id}}, 
                            $parsed_pos, 
                            $oref_array[$index], 
                            $oalt_array[$index], 
                            $filter, 
                            $reason, 
                            $gtr, 
                            $vaf, 
                            $tot_coverage, 
                            $fro, 
                            $fao_array[$alt_index], 
                            $cosid 
                        );
                    }
                }
            }
        }
    }
    return %parsed_data;
}

sub vaf_calc {
    # Determine the VAF
    my $filter = shift;
    my $tcov = shift;
    my $rcov = shift;
    my $acov = shift;

    #local $SIG{__WARN__} = sub {
        #my $message = shift;
        #print $message;
        #print "Affected line: $.\n";
        #print "===============  DEBUG  ==============\n";
        #print "\tfilter:  $$filter\n";
        #print "\ttot cov: $$tcov\n";
        #print "\tref cov: $$rcov\n";
        #print "\talt cov: $$acov\n";
        #print "======================================\n\n";
        #die();
    #};

    my $vaf;

    if ( $$filter eq "NOCALL" ) { 
        $vaf = '.';
    }
    elsif( $$filter eq "NODATA" ) {
        $vaf = 0;
    }
    elsif ( $$tcov == 0 ) {
        $vaf = 0;
    }
    else {
        $vaf = sprintf( "%.2f", 100*($$acov / $$tcov) );
    }

    return $vaf;
}

sub filter_data {
    # Filtered out extracted dataset.
    my $data = shift;
    my $filter = shift;

    my %filtered_data;
    my @fuzzy_pos;
    my %counter;

    if ( $fuzzy ) {
        my $re = qr/(.*).{$fuzzy}/;
        @fuzzy_pos = map { /$re/ } @$filter;
        for my $query ( @fuzzy_pos ) {
            for ( sort keys %$data ) {
                next if ( $ovat_filter && $$data{$_}[11] eq '---' );
                if ( $$data{$_}[0] =~ /$query.{$fuzzy}/ ) {
                    push( @{$filtered_data{$query}},  [@{$$data{$_}}] );
                    $counter{$query} = 1;
                }
            }
        }
    } 
    else {
        for my $variant ( keys %$data ) {
            if ($hsids) {
                if ( my ($query) = grep { ($_) eq $$data{$variant}[10] } @$filter ) {
                    @{$filtered_data{$variant}} = @{$$data{$variant}};
                    $counter{$query} = 1;
                }
            } else {
                if ( my ($query) = grep { ($_) eq $$data{$variant}[0] } @$filter ) {
                    @{$filtered_data{$variant}} = @{$$data{$variant}};
                    $counter{$query} = 1;
                }
            }
        }
    }

    # XXX
    ovat_filter(\%filtered_data) if $ovat_filter;
    format_output( \%filtered_data );
    
    my $term;
    ($hsids) ? ($term = "with Hotspot ID:") : ($term = "at position:");

    if ( $fuzzy ) {
        for my $query ( @fuzzy_pos ) {
            my $string = $query . ( '*' x $fuzzy );
            printf $out_fh "\n>>> No variant found $term %s <<<\n", $string if ( ! exists $counter{$query} );
            exit;
        }
    } else {
        for my $query ( @$filter ) {
            print $out_fh "\n>>> No variant found $term $query <<<\n" if ( ! exists $counter{$query} );
            exit;
        } 
    }
}

sub ovat_filter {
    # Filter out calls that are not oncomine reportable variants
    my $data = shift;

    # Add in the OVAT filter here
    if ( $ovat_filter ) {
        print "$info Running ovat filter\n";
        for my $variant ( keys %$data ) {
            delete $$data{$variant} if $$data{$variant}->[12] eq '---';
        }
    }

    format_output($data);

    print {$out_fh} "\n>>> No Oncomine Annotated Variants Found! <<<\n" unless %$data;
}

sub format_output {
    # Format and print out the results
    my $data = shift;

    my ( $w1, $w2, $w3 ) = field_width( $data );

    if ( $tvc32 ) {
        # FIXME: Formatting for TVCv3.2 data.  Remove when v4.0 fully implemented.
        my $format = "%-19s %-${w1}s %-${w2}s %-10s  %-10s %-10s %-10s %-10s\n";
        printf $out_fh $format, qw{ CHROM:POS REF ALT Bayesian VAF TotCov RefCov AltCov };
        for my $variant (sort keys %$data ) {
            printf $out_fh $format, @{$$data{$variant}};
        }
        exit;
    }

    print "\n";

    # Set up the output header
    my ($format, @header);
    if ($ovat) {
        $format = "%-19s %-${w1}s %-${w2}s %-10s %-${w3}s %-10s %-10s %-10s %-10s %-14s %-12s %-21s %s\n";
        @header = qw( CHROM:POS REF ALT Filter Filter_Reason VAF TotCov RefCov AltCov COSID Gene oncomineGeneClass oncomineVariantClass );
    } else {
        $format = "%-19s %-${w1}s %-${w2}s %-10s %-${w3}s %-10s %-10s %-10s %-10s %s\n";
        @header = qw( CHROM:POS REF ALT Filter Filter_Reason VAF TotCov RefCov AltCov COSID );
    }
    printf $out_fh $format, @header;

    # Need to parse the data stucture differently if fuzzy lookup
    if ( $fuzzy ) {
        for my $variant ( sort { versioncmp( $a, $b ) }  keys %$data ) {
            for my $common_var ( @{$$data{$variant}} ) {
                printf $out_fh $format, @$common_var[0..4,6..13];
            }
        }
    } else {
        for my $variant ( sort { versioncmp( $a, $b ) } keys %$data ) {
            printf $out_fh $format, @{$$data{$variant}}[0..4,6..13];
        }
    }
}

sub field_width {
    # Get the longest field width for formatting later.
    my $data_ref = shift;
    my $ref_width = 0;
    my $var_width = 0;
    my $filter_width= 0;

    if ( $fuzzy ) {
        for my $variant ( keys %$data_ref ) {
            for ( @{$$data_ref{$variant}} ) {
                my $ref_len = length( $$_[1] );
                my $alt_len = length( $$_[2] );
                my $filter_len = length( $$_[4] );
                $ref_width = $ref_len if ( $ref_len > $ref_width );
                $var_width = $alt_len if ( $alt_len > $var_width );
                $filter_width = $filter_len if ( $filter_len > $filter_width );
            }
        }
    } else {
        for my $variant ( keys %$data_ref ) {
            my $ref_len = length( $$data_ref{$variant}[1] );
            my $alt_len = length( $$data_ref{$variant}[2] );
            my $filter_len = length( $$data_ref{$variant}[4] );
            $ref_width = $ref_len if ( $ref_len > $ref_width );
            $var_width = $alt_len if ( $alt_len > $var_width );
            $filter_width = $filter_len if ( $filter_len > $filter_width );
        }
    }

    ( $filter_width > 13 ) ? ($filter_width += 4) : ($filter_width = 17);
    return ( $ref_width + 4, $var_width + 4, $filter_width);
}

sub batch_lookup {
    # Process a lookup file, and load up @query_list
    my $file = shift;
    my @query_list;

    open( my $fh, "<", $$file ) or die "Can't open the lookup file: $!";
    chomp( @query_list = <$fh> );
    close $fh;

    my $query_string = join( ' ', @query_list );
    return \$query_string;
}

sub get_ovat_annot {
    # If this is IR VCF, add in the OVAT annotation. For now just stick with oncomine class data; later
    # can add gene, transcript, etc.
    my $func = shift;
    $$func =~ tr/'/"/;

    my ($gene_class, $variant_class, $gene_name);
    my $json_annot = JSON::XS->new->decode($$func);
    
    # TODO: May need to tweak this. What if FUNC > 1?
    $gene_class = $$json_annot[0]{'oncomineGeneClass'} // '---';
    $variant_class = $$json_annot[0]{'oncomineVariantClass'} // '---';
    $gene_name = $$json_annot[0]{'gene'} // '---';

    return ($gene_class, $variant_class, $gene_name);
}
