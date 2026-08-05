try {
    HttpResponse res = RevConnectCallout.postRev('sales-transaction/actions/place', '{}');
    System.debug('RC_STATUS=' + res.getStatusCode());
    System.debug('RC_BODY=' + res.getBody());
} catch (Exception e) {
    System.debug('RC_EXCEPTION=' + e.getMessage());
    throw e;
}
