/**
 * HTTP client for Revenue Cloud Connect REST under /services/data/v{api}/connect/rev/...
 * Uses a self-referencing Named Credential for auth and endpoint resolution.
 */
public with sharing class RevConnectCallout {
    public static final String DEFAULT_NAMED_CREDENTIAL = 'SelfOrgNC';
    public static final String DEFAULT_API_VERSION = '65.0';

    /**
     * POST to a path under /connect/rev (leading slash optional), e.g. sales-transaction/actions/place
     */
    public static HttpResponse postRev(String pathAfterConnectRev, String jsonBody) {
        return postRev(pathAfterConnectRev, jsonBody, DEFAULT_API_VERSION);
    }

    public static HttpResponse postRev(String pathAfterConnectRev, String jsonBody, String apiVersion) {
        String normalized = pathAfterConnectRev == null ? '' : pathAfterConnectRev.removeStart('/');
        return postDataPath('connect/rev/' + normalized, jsonBody, apiVersion);
    }

    /**
     * POST to a path under /services/data/v{api}/... (leading slash optional).
     */
    public static HttpResponse postDataPath(String pathAfterVersion, String jsonBody) {
        return postDataPath(pathAfterVersion, jsonBody, DEFAULT_API_VERSION);
    }

    public static HttpResponse postDataPath(String pathAfterVersion, String jsonBody, String apiVersion) {
        String normalized = pathAfterVersion == null ? '' : pathAfterVersion.removeStart('/');
        String endpoint = buildEndpoint(DEFAULT_NAMED_CREDENTIAL, apiVersion, '/' + normalized);

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json; charset=UTF-8');
        if (jsonBody != null) {
            req.setBody(jsonBody);
        }
        req.setTimeout(120000);

        return new Http().send(req);
    }

    private static String buildEndpoint(String namedCredential, String apiVersion, String resourcePath) {
        String normalizedVersion = apiVersion == null ? '' : apiVersion.trim();
        if (!normalizedVersion.startsWith('v')) {
            normalizedVersion = 'v' + normalizedVersion;
        }
        return 'callout:' + namedCredential + '/services/data/' + normalizedVersion + resourcePath;
    }
}
