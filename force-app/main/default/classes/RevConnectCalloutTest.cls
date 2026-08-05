@IsTest
private class RevConnectCalloutTest {
    private class MockOk implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            System.assert(req.getEndpoint().contains('callout:SelfOrgNC/services/data/v65.0/connect/rev/sales-transaction/actions/place'));
            System.assertEquals('POST', req.getMethod());
            System.assertEquals(null, req.getHeader('Authorization'));

            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"ok":true}');
            return res;
        }
    }

    @IsTest
    static void postRev_buildsEndpointAndSendsPost() {
        Test.setMock(HttpCalloutMock.class, new MockOk());

        Test.startTest();
        HttpResponse res = RevConnectCallout.postRev(
            'sales-transaction/actions/place',
            '{"pricingPref":"System"}'
        );
        Test.stopTest();

        System.assertEquals(200, res.getStatusCode());
        System.assert(res.getBody().contains('ok'));
    }
}
