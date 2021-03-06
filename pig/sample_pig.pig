/*
    Author: Mukthar.Ahmed@inmobi.com
    Description:
        - Part of MTap reporting pipeline.
        - This script takes adroit's table dumps of reporting_s2s_hourly_app and
        rtfb_metrics_app_hourly and joins them with app-metadata (which has gpm to app id as per
        partner mapping) and then entire data is joined with partner conversion data pulled from
        api and generates enriched reporting data.

    output consumer: The output of this is registered and consumed by lens while a query is
    triggered in from Unified UI.
 */


-- Deleting the output dir if already exists.
rmf $outdir;

/*
    Collect S2s Data
    Steps:
        - Load data
        - Generate
        - Filter by download events only
        - Group by all the keys
        - And generate Grouped data along with SUM
*/
-- load adroit - reporting_s2s_hourly_app data
S2sDataRaw = LOAD '$ins2s/reporting*' USING PigStorage ('\u0001') AS (id:int,
processed_time:chararray, event_time:chararray, app_guid:chararray, goal:chararray,
tracking_partner:chararray, event_type:chararray, hostname:chararray, total_received:int,
published_yoda:int, published_rtfb:int, rtfb_invalid_impid_udc:int, rtfb_invalid_impid_anf:int,
non_inmobi_conversions:int, organic_conversions:int, non_inmobi_post_conversions:int,
organic_post_conversions:int, qualified_yoda_rtfb:int, rtfb_qualified:int);

-- generate only the required fields
S2sRawGenerated = FOREACH S2sDataRaw GENERATE SUBSTRING(event_time, 0, 10) as s2seventtime,
app_guid as appguid, goal as goal, tracking_partner as tracker, total_received as s2sreceived,
rtfb_invalid_impid_udc as invalidimps, non_inmobi_conversions as conversionsnoninmobi,
organic_conversions as conversionsorganic, published_rtfb as tortfb;

S2sFilteredByDownloads = FILTER S2sRawGenerated BY goal == 'download';
S2sFilteredByDownloadsGen = foreach S2sFilteredByDownloads generate s2seventtime, appguid,
goal, tracker, s2sreceived, invalidimps, conversionsnoninmobi, conversionsorganic, tortfb;

-- group
S2sDownloadDataGrouped = GROUP S2sFilteredByDownloadsGen by (s2seventtime, appguid, tracker);

S2sDailyData = FOREACH S2sDownloadDataGrouped GENERATE FLATTEN(group) AS (s2seventtime,
appguid, tracker), SUM(S2sFilteredByDownloadsGen.s2sreceived) as s2sreceived, SUM
(S2sFilteredByDownloadsGen.invalidimps) as invalidimps, (SUM(S2sFilteredByDownloadsGen
.conversionsnoninmobi) - SUM(S2sFilteredByDownloadsGen.conversionsorganic)) as
conversionsnoninmobi, SUM(S2sFilteredByDownloadsGen.conversionsorganic) as conversionsorganic,
SUM(S2sFilteredByDownloadsGen.tortfb) as tortfb;

STORE S2sDailyData INTO '$outdir/s2s-data-daily' USING PigStorage('');


/*
    Collect rtfb table data
    Steps:
        - Load data
        - Generate and while generating, replace all the blank cells by unkonwn
        - Filter data by download
        - Group by keys and generate
        - Store into a ^A delimited flat file
*/

-- load adroit - rtfb_metrics_hourly_app
RtfbRaw = LOAD '$inrtfb/rtfb*' USING PigStorage ('\u0001') AS (app_guid:chararray,
src:chararray, goal:chararray, processed_time:chararray, event_time:chararray, received_goals:int,
unique_goals:int, duplicate_goals:int, hostname:chararray, unmatched_old_impid:int,
unmatched_unknown_reason:int, matched_fraud_click:int);

-- generate only the required fields
RtfbRawGenerated = FOREACH RtfbRaw GENERATE ((app_guid IS NULL or app_guid == '""') ?
'unknown' : app_guid) as appguid, ((src is null or src == '""') ? 'unknown' : src) as src, goal
  as goal, SUBSTRING(processed_time, 0, 10) as rtfbprocessedtime, SUBSTRING(event_time, 0, 10)
  as rtfbeventtime, received_goals as rtfbreceived, unique_goals as rtfbunique, duplicate_goals
  as rtfbduplicate, unmatched_old_impid as unmoldimps, unmatched_unknown_reason as unmunknownimps;

RtfbFilteredByDownloads = filter RtfbRawGenerated BY (goal == 'download');

RtfbFilteredByDownloadsGen = foreach RtfbFilteredByDownloads generate appguid, goal as goal,
rtfbeventtime, rtfbreceived, rtfbunique, rtfbduplicate, unmoldimps, unmunknownimps;

-- group data
RtfbDownloadDataGrouped = GROUP RtfbFilteredByDownloadsGen by (appguid, rtfbeventtime);

RtfbDailyData = FOREACH RtfbDownloadDataGrouped GENERATE FLATTEN(group) AS (appguid,
rtfbeventtime), SUM(RtfbFilteredByDownloadsGen.rtfbreceived) as rtfbreceived, SUM
(RtfbFilteredByDownloadsGen.rtfbunique) as rtfbunique, SUM(RtfbFilteredByDownloadsGen
.rtfbduplicate) as rtfbduplicate, SUM(RtfbFilteredByDownloadsGen.unmoldimps) as unmoldimps, SUM
(RtfbFilteredByDownloadsGen.unmunknownimps) as unmunknownimps;

STORE RtfbDailyData INTO '$outdir/rtfb-data-daily' USING PigStorage('');


/*
    Join S2s and Rtfb tables/daily output files
        - Doing a left outer join so that blanks are also taken forward.
*/
-- left outer join reporting_s2s and rtfb_metrics
AdroitDownloadData = JOIN S2sDailyData by (appguid, s2seventtime) LEFT OUTER,
RtfbDailyData by (appguid, rtfbeventtime);

AdroitDownloadDataGen = foreach AdroitDownloadData generate S2sDailyData::s2seventtime as s2seventtime,
S2sDailyData::appguid as appguid, S2sDailyData::tracker as tracker, S2sDailyData::s2sreceived as s2sreceived,
S2sDailyData::invalidimps as invalidimps, S2sDailyData::conversionsnoninmobi as strandsandoffnet,
 S2sDailyData::conversionsorganic as conversionsorganic, S2sDailyData::tortfb as tortfb,
 RtfbDailyData::rtfbreceived as rtfbreceived, RtfbDailyData::rtfbunique as rtfbunique,
RtfbDailyData::rtfbduplicate as rtfbduplicate, RtfbDailyData::unmoldimps as unmoldimps,
RtfbDailyData::unmunknownimps as unmunknownimps;

Store AdroitDownloadDataGen into '$outdir/adroit-data-daily' using PigStorage('');


/* Processing app meta file for further enhancing partner data
*/
-- load app_meta file
AppMetadata = LOAD '$appmeta' USING PigStorage ('\u0001') AS (id:chararray, created_on:chararray,
app_guid:chararray, app_name:chararray, app_url:chararray, partner_app_id:chararray);

-- generate app_meta
AppMetadataGenerated = foreach AppMetadata generate app_guid as appguid, app_name as appname,
app_url as appurl, partner_app_id as partnerappid;

AdroitToAppmetaJoin = JOIN AdroitDownloadDataGen by (appguid) LEFT OUTER, AppMetadataGenerated by
(appguid);

AdroitComplete = foreach AdroitToAppmetaJoin generate AdroitDownloadDataGen::s2seventtime as
s2seventtime, AdroitDownloadDataGen::appguid as appguid, AdroitDownloadDataGen::tracker as tracker,
AdroitDownloadDataGen::s2sreceived as s2sreceived, AdroitDownloadDataGen::invalidimps as
invalidimps, AdroitDownloadDataGen::strandsandoffnet as strandsandoffnet,
AdroitDownloadDataGen::conversionsorganic as conversionsorganic, AdroitDownloadDataGen::tortfb as tortfb,
AdroitDownloadDataGen::rtfbreceived as rtfbreceived, AdroitDownloadDataGen::rtfbunique as rtfbunique,
AdroitDownloadDataGen::rtfbduplicate as rtfbduplicate, AdroitDownloadDataGen::unmoldimps as unmoldimps,
AdroitDownloadDataGen::unmunknownimps as unmunknownimps, AppMetadataGenerated::partnerappid as
partnerappid, AppMetadataGenerated::appurl as appurl;

Store AdroitComplete into '$outdir/adroit-complete' using PigStorage('');

/*
    Generate MTap partner data
        - Load partner data
        - Group data by its unique keys
        - Generate and write to a ^A delimited flat file
*/
PartnerDataRaw = LOAD '$partnerdata/partner*' USING PigStorage ('\u0001') AS (partner:chararray,
ts_partner:chararray, advertiser_id:chararray, ad_clicks:int, ad_clicks_unique:int, installs:int,
paid_installs_assists:int, paid_installs_total:int, app_id:chararray, app_name:chararray);

-- generate the partner data field
PartnerDataRawGenerated = foreach PartnerDataRaw generate partner as partner, SUBSTRING(ts_partner, 0,
 10) as partnereventtime, advertiser_id as advid, ad_clicks as adclicks, ad_clicks_unique as
 adclicksunique, installs as installs, paid_installs_total as paidinstallstotal,
 paid_installs_assists as paidinstallsassists, app_id as appid, app_name as appname;

-- group data
PartnerDataRawGrouped = GROUP PartnerDataRawGenerated by (partner, partnereventtime, advid, appid,
 appname);

-- generate grouped data
PartnerDataDailyRaw = foreach PartnerDataRawGrouped generate flatten(group) as (partner,
partnereventtime, advid, appid, appname), SUM(PartnerDataRawGenerated.installs) as
partnerinstalls, SUM(PartnerDataRawGenerated.paidinstallsassists) as paidinstallassists, SUM
(PartnerDataRawGenerated.paidinstallstotal) as paidinstallstotal, SUM(PartnerDataRawGenerated
.adclicks) as adclicks, SUM(PartnerDataRawGenerated.adclicksunique) as adclicksunique;

STORE PartnerDataDailyRaw into '$outdir/partner-raw-data-daily' using PigStorage('');

-- join and Adroit data with partner api data
PartnerDataWithMetadata = JOIN PartnerDataDailyRaw by (partnereventtime, appid) LEFT OUTER,
AdroitComplete by (s2seventtime, partnerappid);


MTapEnrichedData =  foreach PartnerDataWithMetadata generate AdroitComplete::s2seventtime as
s2seventtime, AdroitComplete::partnerappid as partnerappid, AdroitComplete::appguid as appguid,
PartnerDataDailyRaw::appname as appnameaspartner, PartnerDataDailyRaw::advid as advidaspartner,
AdroitComplete::tracker as tracker, PartnerDataDailyRaw::partnerinstalls as partnerinstalls,
AdroitComplete::s2sreceived as s2sreceived, AdroitComplete::tortfb as tortfb,
AdroitComplete::rtfbreceived as rtfbreceived, AdroitComplete::rtfbunique as rtfbunique,
AdroitComplete::rtfbduplicate as rtfbduplicate, AdroitComplete::invalidimps as invalidimps,
AdroitComplete::strandsandoffnet as strandsandoffnet, AdroitComplete::conversionsorganic as
conversionsorganic, AdroitComplete::unmoldimps as unmoldimps, AdroitComplete::unmunknownimps
as unmunknownimps, PartnerDataDailyRaw::adclicks as adclicks, PartnerDataDailyRaw::adclicksunique
 as adclicksunique, PartnerDataDailyRaw::paidinstallassists as paidinstallassists,
 PartnerDataDailyRaw::paidinstallstotal as paidinstallstotal, AdroitComplete::appurl as appurl;


/*
s2seventtime, appidpartner, appguidim, appnamepartner, advertiserid, tracker, partnerinstalls,
s2sreceived, tortfb, rtfbreceived, rtfbunique, rtfbduplicate, invalidimps, strandsandoffnet,
conversionsorganic, unmoldimps, unmunknownimps, adclicks, adclicksunique, paidinstallassists,
paidinstallstotal, appurl;
*/
MTapEnrichedDataFinal = foreach MTapEnrichedData generate s2seventtime, ((partnerappid is null) ?
 'unkonwn' : partnerappid) as partnerappid, ((appguid is null) ? 'unknown' : appguid) as appguid,
 ((appnameaspartner is null) ? 'unknown' : appnameaspartner) as appnameaspartner,
 ((advidaspartner is null) ? 'unknown' : advidaspartner) as advidaspartner, ((tracker is null) ?
 'unknown' : tracker) as tracker, ((partnerinstalls is null) ? 0 : partnerinstalls) as
 partnerinstalls, ((s2sreceived is null) ? 0 : s2sreceived) as s2sreceived, ((tortfb is null) ? 0
  : tortfb) as tortfb, ((rtfbreceived is null) ? 0 : rtfbreceived) as rtfbreceived, ((rtfbunique
  is null) ? 0 : rtfbunique) as rtfbunique, ((rtfbduplicate is null) ? 0 : rtfbduplicate) as
  rtfbduplicate,  ((invalidimps is null) ? 0 : invalidimps) as invalidimps, ((strandsandoffnet is
   null) ? 0 : strandsandoffnet) as strandsandoffnet, ((conversionsorganic is null) ? 0 :
   conversionsorganic) as conversionsorganic, ((unmoldimps is null) ? 0 : unmoldimps) as
   unmoldimps, ((unmunknownimps is null) ? 0 : unmunknownimps) as unmunknownimps, ((adclicks is
  null) ? 0 : adclicks) as adclicks, ((adclicksunique is null) ? 0 : adclicksunique) as
  adclicksunique, ((paidinstallassists is null) ? 0 : paidinstallassists) as paidinstallassists,
  ((paidinstallstotal is null) ? 0 : paidinstallstotal) as paidinstallstotal, ((appurl is null) ?
 'UNKNOWN' : appurl) as appurl;


--Store MTapEnrichedData INTO '$outdir/enriched/' USING PigStorage('');
Store MTapEnrichedDataFinal INTO '$outdir/enriched/' USING PigStorage('');

