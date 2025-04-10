#!/usr/bin/perl
# geierb@geierb.de
# AGPLv3

use strict;
use WWW::Mechanize;
use WWW::Mechanize::GZip;
use HTML::Entities;
use HTML::TreeBuilder;
use HTML::Strip;

use HTTP::Request::Common;

use JSON;

use Data::ICal;
use Data::ICal::Entry::Event;

use Try::Tiny;

use utf8;
use warnings;

use Encode;

#use Data::Dumper;

# Z-Bau already provides an ICS file for each event
# This script filters fetches them all, and merges them together

my $URL="https://z-bau.com/programm";

my $calendar=Data::ICal->new();
$calendar->add_properties(method=>"PUBLISH",
    "X-PUBLISHED-TTL"=>"P1D",
    "X-WR-CALNAME"=>"Z-Bau",
    "X-WR-CALDESC"=>"Veranstaltungen Z-Bau");

# avoid "wide character" warnings
binmode STDOUT, ":utf8";
my $mech=WWW::Mechanize::GZip->new();

my $htmlStripper=HTML::Strip->new();

$mech->get($URL) or die($!);
my $tree=HTML::TreeBuilder->new_from_content($mech->content());

# Get APP ID, API-Key and API server from events-BLABLA.js script
# 1. figure out script URL
my $eventScriptUrl=$tree->look_down('_tag'=>'head')->look_down('_tag'=>'script', 'src'=>qr/\/events\-.*.js$/)->{'src'};
# 2. fetch script
my $eventScript=$mech->get($eventScriptUrl)->content;
# 3 extract info
my ($SEARCH_API_KEY)=($eventScript=~/VITE_ALGOLIA_SEARCH_API_KEY:\"(.+?)\"/);
my ($APP_ID)=($eventScript=~/VITE_ALGOLIA_APP_ID:\"(.+?)\"/);
my $API_SERVER="https://".lc($APP_ID)."-dsn.algolia.net";

# Use API call to search for events "*", returns JSON
my $ua=LWP::UserAgent->new;
my $request=HTTP::Request::Common::POST(
    $API_SERVER.'/1/indexes/*/queries',
    "x-algolia-api-key" => $SEARCH_API_KEY,
    "x-algolia-application-id" => $APP_ID,
    Content => '{"requests":[{"indexName":"zbau-001","params":"facetFilters=%5B%5B%22is_beergarden%3A0%22%5D%2C%5B%22is_past%3A0%22%5D%5D&facets=%5B%22date_filter_string%22%2C%22is_beergarden%22%2C%22is_past%22%2C%22type%22%5D&highlightPostTag=__%2Fais-highlight__&highlightPreTag=__ais-highlight__&maxValuesPerFacet=1000&page=0&query="},{"indexName":"zbau-001","params":"analytics=false&clickAnalytics=false&facetFilters=%5B%5B%22is_past%3A0%22%5D%5D&facets=is_beergarden&highlightPostTag=__%2Fais-highlight__&highlightPreTag=__ais-highlight__&hitsPerPage=0&maxValuesPerFacet=1000&page=0&query="},{"indexName":"zbau-001","params":"analytics=false&clickAnalytics=false&facetFilters=%5B%5B%22is_beergarden%3A0%22%5D%5D&facets=is_past&highlightPostTag=__%2Fais-highlight__&highlightPreTag=__ais-highlight__&hitsPerPage=0&maxValuesPerFacet=1000&page=0&query="}]}'
);
my $response=$ua->request($request) or die($!);

my $data = JSON::decode_json($response->content);

# Loop through results and fetch ICS for each event
foreach my $result (@{$data->{'results'}[0]->{'hits'}}) {

    my $price=$htmlStripper->parse($result->{'_highlightResult'}->{'price'}->{'value'});
    $price=~s/^\s*(?:Eintritt:)?\s*//;

    my $presaleUrl=$result->{'presale'};

    my $subtitle=$result->{'subtitle'};

    my $calendarUrl=$result->{'calendar_file_url'};

    # Fetch ICS
    $mech->get($calendarUrl) or die ($!);

    # Parse ICS
    my @filtered;
    my @lines=split /\n/, decode('UTF-8',$mech->content());
    foreach my $line (@lines) {
        # Data::ICal::Entry does not understand REFRESH-INTERVAL, so filter that out
	next if $line=~/^refresh-interval/i;

	# add subtitle, price and presaleUrl to DESCRIPTION
	if ($line=~/^(DESCRIPTION:)(.*)/) {
	    $line=$1.$subtitle.'\n\nEintritt: '.$price.'\nVorverkauf: '.$presaleUrl.'\n'.$2;
	}

        push(@filtered,$line) unless $line=~/^refresh-interval/i;
    }
    my $zCalendar=Data::ICal->new(data=>join("\n", @filtered));


    # Append to calendar
    foreach my $entry (@{$zCalendar->entries}) {
	$calendar->add_entry($entry);

    }
}

print $calendar->as_string;
