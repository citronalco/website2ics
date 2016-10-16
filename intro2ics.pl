#!/usr/bin/perl
# 2014 geierb@geierb.de
# GPLv3

use strict;
use WWW::Mechanize;
use HTML::Entities;
use HTML::Strip;
use HTML::TreeBuilder;

use DateTime::Format::Strptime;
use Data::ICal;
use Data::ICal::Entry::Event;
use Date::ICal;
use Time::HiRes;

use Try::Tiny;

use utf8;
use open qw(:std :utf8);

use Data::Dumper;
use warnings;

#my @cities=("ingolstadt","muenchen","nuernberg");
my @cities=@ARGV;

if (@cities==0) {
    print "Give me city names for which to look for upcoming events.\n";
    print "Example: ".$0." ingolstadt muenchen nuernberg\n\n";
    exit 1;
}

binmode STDOUT, ":utf8";	# Gegen "wide character"-Warnungen

my $mech=WWW::Mechanize->new();
my $hs=HTML::Strip->new();
my @events;

foreach my $city (@cities) {
    my $url="http://www.intro.de/termine/".lc($city)."/seite/";
    my $seite=1;

    do {
	$mech->get($url.$seite++) or die($!);
	my $root=HTML::TreeBuilder->new_from_content($mech->content());

	foreach my $day ($root->look_down('_tag'=>'div','class'=>'date item')) {
	    foreach my $event ($day->look_down('_tag'=>'li')) {
		my $eventData;
		my $moreLink=$event->look_down('_tag'=>'a')->attr('href');
		$moreLink=~/.+?\/.+?\/(\d{4})-(\d{2})-(\d{2})\//;

		$eventData->{'beginn'}=DateTime->new(year=>$1,month=>$2,day=>$3);

#		$eventData->{'ende'}=$eventData->{'beginn'}->clone();
#		$eventData->{'ende'}->add(days=>1);

		$eventData->{'name'}=$event->look_down('_tag'=>'p','class'=>'artist')->as_text;

		($eventData->{'location'})=$event->look_down('_tag'=>'p','class'=>'name')->as_text=~/^\s*(.*?)\s*$/;

		$mech->follow_link('url'=>$moreLink);
		my $root2=HTML::TreeBuilder->new_from_content($mech->content());

		my @moreInfo=split(/<br\s*\/><br\s*\/>/,$root2->look_down('_tag'=>'p','id'=>'first-paragraph')->as_HTML);
		foreach my $currentMoreInfo (@moreInfo) {
		    my $currentMoreInfoText=$hs->parse($currentMoreInfo);
		    $currentMoreInfoText=~s/^\s*//;
		    $currentMoreInfoText=~s/\s*$//;
		    if ($currentMoreInfoText=~/^Location/) {
			my @loc=$currentMoreInfoText=~/^Location:\s+($eventData->{'location'})\s*(.*?)$/;
			$eventData->{'location'}=join(", ",@loc);
		    }
		    elsif ($currentMoreInfoText=~/^$eventData->{'location'}$/) {
			next;
		    }
		    else {
			$eventData->{'description'}= $currentMoreInfoText;
		    }
		}
		$mech->back();
		push(@events,$eventData);
	    }
	}
    } while($mech->find_link('class'=>'arrow next'));
} 


# Create Datestamp for dtstamp
my @stamp=localtime;
my $dstamp = sprintf("%d%02d%02dT%02d%02d%02dZ",
    $stamp[5] + 1900,
    $stamp[4] + 1,
    $stamp[3],
    $stamp[2],
    $stamp[1],
    $stamp[0]);


my $calendar=Data::ICal->new();
$calendar->add_properties(method=>"PUBLISH",
	"X-PUBLISHED-TTL"=>"P1D",
	"X-WR-CALNAME"=>"Intro.de",
	"X-WR-CALDESC"=>"Veranstaltungen in ".join(", ",map{ucfirst lc} @cities));

my $count=0;
foreach my $event (@events) {
    # Create uid
    my @tm=localtime();
    my $uid=sprintf("%d%02d%02d%02d%02d%02d%s%02d\@geierb.de",
                    $tm[5] + 1900, $tm[4] + 1, $tm[3], $tm[2],
                    $tm[1], $tm[0], scalar(Time::HiRes::gettimeofday()), $count);

    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	summary => $event->{'name'},
	description => $event->{'description'},
	dtstart=>sprintf("%04d%02d%02dT000000",$event->{'beginn'}->year,$event->{'beginn'}->month,$event->{'beginn'}->day),
	dtend=>sprintf("%04d%02d%02dT235959",$event->{'beginn'}->year,$event->{'beginn'}->month,$event->{'beginn'}->day),
#	all_day=>'1',
#	duration=>"PT3H",
	dtstamp=>$dstamp,
	class=>"PUBLIC",
#	organizer=>$event->{'veranstalter'},
        organizer=>"MAILTO:foobar",
	location=>$event->{'location'},
#	url=>$event->{'url'},
    );

    $calendar->add_entry($eventEntry);
    $count++;
}

print $calendar->as_string;
