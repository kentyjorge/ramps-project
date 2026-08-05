/**
 * Quote-level group ramp: new flow — all lines in segment 1, selected lines duplicated into segment 2…N via AddProducts.
 */
public with sharing class QuoteRampController {
    public class LineRow {
        @AuraEnabled public String id;
        @AuraEnabled public String productName;
        @AuraEnabled public String quoteLineGroupId;
        @AuraEnabled public String parentQuoteLineItemId;
        @AuraEnabled public Integer lineNumber;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal pricingTerm;
    }

    public class GroupRow {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public Integer sortOrder;
        @AuraEnabled public Boolean isRamped;
        @AuraEnabled public String segmentType;
    }

    public class ContextPayload {
        @AuraEnabled public List<LineRow> lines;
        @AuraEnabled public List<GroupRow> groups;
    }

    public class SegmentInput {
        public String segmentType;
        public String startDate;
        public String endDate;
        public Decimal uplift;   // maps to QuoteLineItem.UnitPriceUplift
        public Decimal discount; // maps to QuoteLineItem.Discount
        public String name;      // maps to QuoteLineGroup.Name
    }

    @AuraEnabled(cacheable=true)
    public static ContextPayload getQuoteRampContext(Id quoteId) {
        if (quoteId == null) {
            throw new AuraHandledException('Quote Id is required.');
        }
        assertQuoteAccess(quoteId);

        ContextPayload ctx = new ContextPayload();
        ctx.lines = new List<LineRow>();
        ctx.groups = new List<GroupRow>();

        for (QuoteLineItem qli : [
            SELECT
                Id,
                LineNumber,
                Quantity,
                PricingTerm,
                QuoteLineGroupId,
                ParentQuoteLineItemId,
                Product2.Name
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            ORDER BY LineNumber NULLS LAST, CreatedDate
        ]) {
            LineRow row = new LineRow();
            row.id = qli.Id;
            row.productName = qli.Product2 != null ? qli.Product2.Name : '';
            row.quoteLineGroupId = qli.QuoteLineGroupId;
            row.parentQuoteLineItemId = qli.ParentQuoteLineItemId;
            row.lineNumber = toInteger(qli.LineNumber);
            row.quantity = qli.Quantity;
            row.pricingTerm = qli.PricingTerm;
            ctx.lines.add(row);
        }

        for (QuoteLineGroup g : [
            SELECT Id, Name, SortOrder, IsRamped, SegmentType
            FROM QuoteLineGroup
            WHERE QuoteId = :quoteId
            ORDER BY SortOrder NULLS LAST, Name
        ]) {
            GroupRow gr = new GroupRow();
            gr.id = g.Id;
            gr.name = g.Name;
            gr.sortOrder = g.SortOrder;
            gr.isRamped = g.IsRamped == true;
            gr.segmentType = g.SegmentType;
            ctx.groups.add(gr);
        }

        return ctx;
    }

    /**
     * New flow: create/resolve segment-1 group, move ALL lines there, ramp N segments, then AddProducts into segment 2…N.
     * @param additionalSegmentLinesJson Map as JSON: { "2": ["lineId"], "3": ["lineId1","lineId2"] } keys are 1-based segment numbers (2…N)
     */
    @AuraEnabled
    public static void applyGroupRamp(Id quoteId, String segmentsJson, String additionalSegmentLinesJson) {
        if (quoteId == null) {
            throw new AuraHandledException('Quote Id is required.');
        }
        if (String.isBlank(segmentsJson)) {
            throw new AuraHandledException('Segment definition is required.');
        }

        assertQuoteAccess(quoteId);

        List<SegmentInput> segments = parseSegments(segmentsJson);
        if (segments.isEmpty()) {
            throw new AuraHandledException('At least one segment is required.');
        }

        Map<String, List<String>> additionalBySegment = parseAdditionalSegmentLines(additionalSegmentLinesJson);

        List<QuoteLineItem> allLines = [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
        ];
        if (allLines.isEmpty()) {
            throw new AuraHandledException('Add products to the quote before applying a ramp.');
        }
        List<Id> allLineIds = new List<Id>();
        for (QuoteLineItem q : allLines) {
            allLineIds.add(q.Id);
        }

        GroupOneResult groupOneResult = ensureSegmentOneGroup(quoteId, allLineIds, segments);
        Id groupOneId = groupOneResult.groupId;

        // 1) All lines → segment 1 group. Skipped when ensureSegmentOneGroup just created the
        // group via the GroupAll action, since GroupAll already moved every ungrouped line into it.
        if (!groupOneResult.wasCreated) {
            String groupAllBody = buildGroupQuoteLinesPayload(quoteId, groupOneId, allLineIds);
            throwIfNotOk(RevConnectCallout.postRev('sales-transaction/actions/place', groupAllBody));
        }

        QuoteLineGroup g1 = [
            SELECT Id, SortOrder
            FROM QuoteLineGroup
            WHERE Id = :groupOneId
            LIMIT 1
        ];
        Integer expectedSort = g1.SortOrder != null ? g1.SortOrder : 1;

        SegmentInput first = segments[0];
        String segmentTypeApi = mapSegmentType(first.segmentType);

        // 2) First ramp segment (EditGroup on group 1)
        String editGroupBody = buildEditGroupPayload(quoteId, groupOneId, first, segmentTypeApi, expectedSort);
        throwIfNotOk(RevConnectCallout.postRev('sales-transaction/actions/place', editGroupBody));

        // 2b) Temporarily ungroup one-time bundles via Revenue Connect so clone doesn't include them.
        // Rule: if a root parent (no ParentQuoteLineItemId) is OneTime, the entire bundle goes to "One Time" group.
        List<QuoteLineItem> oneTimeRoots = [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
              AND QuoteLineGroupId = :groupOneId
              AND SellingModelType = 'OneTime'
              AND ParentQuoteLineItemId = NULL
        ];
        Set<Id> oneTimeRootIds = new Set<Id>();
        for (QuoteLineItem qli : oneTimeRoots) {
            oneTimeRootIds.add(qli.Id);
        }
        List<QuoteLineItem> oneTimeChildren = new List<QuoteLineItem>();
        if (!oneTimeRootIds.isEmpty()) {
            oneTimeChildren = [
                SELECT Id
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId
                  AND ParentQuoteLineItemId IN :oneTimeRootIds
            ];
        }
        List<QuoteLineItem> oneTimeLines = new List<QuoteLineItem>();
        oneTimeLines.addAll(oneTimeRoots);
        oneTimeLines.addAll(oneTimeChildren);
        if (!oneTimeLines.isEmpty()) {
            List<Id> oneTimeLineIds = new List<Id>();
            for (QuoteLineItem qli : oneTimeLines) {
                oneTimeLineIds.add(qli.Id);
            }
            throwIfNotOk(RevConnectCallout.postRev(
                'sales-transaction/actions/place',
                buildUngroupLinesPayload(quoteId, oneTimeLineIds)
            ));
        }

        // 3) Clone additional ramp segments (N-1)
        for (Integer i = 1; i < segments.size(); i++) {
            Id cloneSourceGroupId = findLastRampedGroupId(quoteId);
            if (cloneSourceGroupId == null) {
                throw new AuraHandledException(
                    'Could not find the last ramp segment to clone. Verify segment 1 was created as ramped.'
                );
            }
            Id fallbackCloneLineId = findPrimaryRampedGroupLineId(quoteId, cloneSourceGroupId);
            String groupCloneBody = buildClonePayload(quoteId, cloneSourceGroupId, true);
            logLong('RevConnect clone payload (group)', groupCloneBody);
            HttpResponse cloneRes = RevConnectCallout.postRev('sales-transaction/actions/clone', groupCloneBody);
            if (isSuccessStatus(cloneRes)) {
                continue;
            }
            String cloneBody = cloneRes != null ? cloneRes.getBody() : null;
            if (isClonePrimarySegmentError(cloneBody) && fallbackCloneLineId != null) {
                String lineCloneBody = buildClonePayload(quoteId, fallbackCloneLineId, true);
                logLong('RevConnect clone payload (line fallback)', lineCloneBody);
                HttpResponse fallbackRes = RevConnectCallout.postRev('sales-transaction/actions/clone', lineCloneBody);
                throwIfNotOk(fallbackRes);
                continue;
            }
            throwIfNotOk(cloneRes);
        }

        // 4) Align dates on all ramped groups
        List<QuoteLineGroup> ramped = [
            SELECT Id, SortOrder
            FROM QuoteLineGroup
            WHERE QuoteId = :quoteId AND IsRamped = TRUE
            ORDER BY SortOrder ASC NULLS LAST, Name
        ];
        if (ramped.size() < segments.size()) {
            throw new AuraHandledException(
                'Expected ' +
                    segments.size() +
                    ' ramped group(s) but found ' +
                    ramped.size() +
                    '. Verify Revenue Cloud ramp settings and clone behavior in this org.'
            );
        }
        List<QuoteLineGroup> ordered = new List<QuoteLineGroup>();
        for (Integer j = 0; j < segments.size(); j++) {
            ordered.add(ramped[j]);
        }
        throwIfNotOk(
            RevConnectCallout.postRev('sales-transaction/actions/place', buildEditRampSchedulePayload(quoteId, ordered, segments))
        );

        // 4b) Create a separate non-ramped "One Time" group and move one-time lines there
        if (!oneTimeLines.isEmpty()) {
            List<Id> oneTimeLineIds = new List<Id>();
            for (QuoteLineItem qli : oneTimeLines) {
                oneTimeLineIds.add(qli.Id);
            }
            throwIfNotOk(RevConnectCallout.postRev(
                'sales-transaction/actions/place',
                buildOneTimeGroupPayload(quoteId, oneTimeLineIds)
            ));
        }

        // 5) AddProducts: segment 2…N — duplicate selected lines into those groups
        Map<Id, QuoteLineItem> lineById = new Map<Id, QuoteLineItem>(
            [
                SELECT
                    Id,
                    Product2Id,
                    PricebookEntryId,
                    Quantity,
                    UnitPrice,
                    QuoteId,
                    ParentQuoteLineItemId,
                    BillingFrequency,
                    PeriodBoundary
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId
            ]
        );

        Map<Id, Set<Id>> sourceLineIdsByTargetGroup = new Map<Id, Set<Id>>();
        Map<Id, SegmentInput> segByTargetGroup = new Map<Id, SegmentInput>();
        for (Integer segNum = 2; segNum <= segments.size(); segNum++) {
            List<String> rawIds = additionalBySegment.get(String.valueOf(segNum));
            if (rawIds == null || rawIds.isEmpty()) {
                continue;
            }
            Set<Id> expanded = expandSelectionWithBundles(lineById, rawIds);
            if (expanded.isEmpty()) {
                continue;
            }
            Id targetGroupId = ordered[segNum - 1].Id;
            Set<Id> deduped = removeProductsAlreadyInGroup(targetGroupId, expanded, lineById);
            if (deduped.isEmpty()) {
                continue;
            }
            sourceLineIdsByTargetGroup.put(targetGroupId, deduped);
            segByTargetGroup.put(targetGroupId, segments[segNum - 1]);
        }
        if (!sourceLineIdsByTargetGroup.isEmpty()) {
            String addBody = buildAddProductsPayloadMulti(quoteId, sourceLineIdsByTargetGroup, segByTargetGroup, lineById);
            if (String.isNotBlank(addBody)) {
                throwIfNotOk(RevConnectCallout.postRev('sales-transaction/actions/place', addBody));
            }
        }

        // 6) Apply per-segment Uplift/Discount and propagate SegmentType to line items,
        // across all ramped groups, in a single combined Revenue Connect call.
        applySegmentAttributesAcrossGroups(quoteId, ordered, segments);

        // 7) Update Quote-level dates and term from segment definitions
        updateQuoteDates(quoteId, segments);
    }

    private class GroupOneResult {
        Id groupId;
        Boolean wasCreated;
    }

    private static GroupOneResult ensureSegmentOneGroup(Id quoteId, List<Id> allLineIds, List<SegmentInput> segments) {
        List<QuoteLineGroup> existing = [
            SELECT Id
            FROM QuoteLineGroup
            WHERE QuoteId = :quoteId
            ORDER BY SortOrder ASC NULLS LAST, CreatedDate ASC
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            GroupOneResult r = new GroupOneResult();
            r.groupId = existing[0].Id;
            r.wasCreated = false;
            return r;
        }

        String seg1Name = (segments != null && !segments.isEmpty() && String.isNotBlank(segments[0].name))
            ? segments[0].name
            : 'Ramp - Segment 1';
        throwIfNotOk(RevConnectCallout.postRev('sales-transaction/actions/place', buildInitialGroupAllPayload(quoteId, seg1Name)));

        List<QuoteLineGroup> created = [
            SELECT Id
            FROM QuoteLineGroup
            WHERE QuoteId = :quoteId
            ORDER BY SortOrder ASC NULLS LAST, CreatedDate ASC
            LIMIT 1
        ];
        if (created.isEmpty()) {
            throw new AuraHandledException(
                'Revenue Connect did not create a quote line group. Verify Revenue Cloud permissions and quote state.'
            );
        }
        GroupOneResult r = new GroupOneResult();
        r.groupId = created[0].Id;
        r.wasCreated = true;
        return r;
    }

    private static String buildInitialGroupAllPayload(Id quoteId, String groupName) {
        String q = String.valueOf(quoteId);
        String safeName = String.isNotBlank(groupName) ? groupName : 'Ramp - Segment 1';
        return '{' +
            '"pricingPref": "Force",' +
            '"catalogRatesPref": "Skip",' +
            buildConfigurationPrefJson() +
            ',' +
            '"graph": {' +
            '"graphId": "groupQuote",' +
            '"records": [' +
            '{ "referenceId": "refQuote", "record": { "attributes": { "type": "Quote", "method": "PATCH", "id": "' +
            q +
            '" } } },' +
            '{ "referenceId": "refQlg1", "record": { "attributes": { "type": "QuoteLineGroup", "method": "POST", "action": "GroupAll" },' +
            '"Name": "' + safeName + '",' +
            '"QuoteId": "@{refQuote.id}"' +
            ' } }' +
            ']' +
            '}' +
            '}';
    }

    private static Map<String, List<String>> parseAdditionalSegmentLines(String jsonStr) {
        Map<String, List<String>> out = new Map<String, List<String>>();
        if (String.isBlank(jsonStr)) {
            return out;
        }
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
        for (String key : root.keySet()) {
            List<Object> arr = (List<Object>) root.get(key);
            List<String> ids = new List<String>();
            if (arr != null) {
                for (Object o : arr) {
                    if (o != null) {
                        ids.add(String.valueOf(o));
                    }
                }
            }
            out.put(key, ids);
        }
        return out;
    }

    /**
     * Include bundle children when a parent or any member is selected (same root subtree).
     */
    private static Set<Id> expandSelectionWithBundles(Map<Id, QuoteLineItem> lineById, List<String> selectedIds) {
        Set<Id> selected = new Set<Id>();
        for (String s : selectedIds) {
            if (!String.isBlank(s)) {
                selected.add((Id) s);
            }
        }
        Map<Id, Id> parentById = new Map<Id, Id>();
        Map<Id, List<Id>> childrenByParent = new Map<Id, List<Id>>();
        for (QuoteLineItem q : lineById.values()) {
            if (q.ParentQuoteLineItemId != null) {
                parentById.put(q.Id, q.ParentQuoteLineItemId);
                if (!childrenByParent.containsKey(q.ParentQuoteLineItemId)) {
                    childrenByParent.put(q.ParentQuoteLineItemId, new List<Id>());
                }
                childrenByParent.get(q.ParentQuoteLineItemId).add(q.Id);
            }
        }
        Set<Id> roots = new Set<Id>();
        for (Id sid : selected) {
            Id root = sid;
            while (parentById.containsKey(root)) {
                root = parentById.get(root);
            }
            roots.add(root);
        }
        Set<Id> expanded = new Set<Id>();
        for (Id root : roots) {
            expanded.add(root);
            addDescendants(root, childrenByParent, expanded);
        }
        return expanded;
    }

    private static void addDescendants(Id parent, Map<Id, List<Id>> childrenByParent, Set<Id> expanded) {
        if (!childrenByParent.containsKey(parent)) {
            return;
        }
        for (Id c : childrenByParent.get(parent)) {
            expanded.add(c);
            addDescendants(c, childrenByParent, expanded);
        }
    }

    private static Set<Id> removeProductsAlreadyInGroup(Id targetGroupId, Set<Id> sourceLineIds, Map<Id, QuoteLineItem> lineById) {
        Set<Id> existingProductIds = new Set<Id>();
        for (QuoteLineItem qli : [
            SELECT Product2Id
            FROM QuoteLineItem
            WHERE QuoteLineGroupId = :targetGroupId
        ]) {
            if (qli.Product2Id != null) {
                existingProductIds.add(qli.Product2Id);
            }
        }

        Set<Id> out = new Set<Id>();
        for (Id lineId : sourceLineIds) {
            QuoteLineItem src = lineById.get(lineId);
            if (src == null || src.Product2Id == null) {
                continue;
            }
            if (!existingProductIds.contains(src.Product2Id)) {
                out.add(lineId);
            }
        }
        return out;
    }

    private static String quotePatchAnchor(String quoteId) {
        return '{ "referenceId": "' +
            quoteId +
            '", "record": { "attributes": { "type": "Quote", "method": "PATCH", "id": "' +
            quoteId +
            '" } } }';
    }

    private static String groupPatchAnchor(String groupId) {
        return '{ "referenceId": "' +
            groupId +
            '", "record": { "attributes": { "type": "QuoteLineGroup", "method": "PATCH", "id": "' +
            groupId +
            '" } } }';
    }

    /**
     * Builds a single AddProducts graph spanning every target segment that has additional lines,
     * instead of one Revenue Connect call per segment.
     */
    private static String buildAddProductsPayloadMulti(
        Id quoteId,
        Map<Id, Set<Id>> sourceLineIdsByTargetGroup,
        Map<Id, SegmentInput> segByTargetGroup,
        Map<Id, QuoteLineItem> lineById
    ) {
        String q = String.valueOf(quoteId);
        List<String> records = new List<String>();
        records.add(quotePatchAnchor(q));

        Integer ref = 0;
        for (Id targetGroupId : sourceLineIdsByTargetGroup.keySet()) {
            Set<Id> sourceLineIds = sourceLineIdsByTargetGroup.get(targetGroupId);
            if (sourceLineIds == null || sourceLineIds.isEmpty()) {
                continue;
            }
            String g = String.valueOf(targetGroupId);
            records.add(groupPatchAnchor(g));

            SegmentInput segRow = segByTargetGroup.get(targetGroupId);
            String startIso = (segRow != null && segRow.startDate != null) ? segRow.startDate + 'T00:00:00.000Z' : '';

            for (Id lid : sourceLineIds) {
                QuoteLineItem src = lineById.get(lid);
                if (src == null) {
                    continue;
                }
                String refId = 'addLine_' + String.valueOf(ref);
                ref++;
                String pbe = String.valueOf(src.PricebookEntryId);
                String p2 = String.valueOf(src.Product2Id);
                String qty = src.Quantity == null ? '1' : String.valueOf(src.Quantity);
                String price = src.UnitPrice == null ? '0' : String.valueOf(src.UnitPrice);
                String billingFrequency = String.valueOf(src.BillingFrequency);
                String periodBoundary = String.valueOf(src.PeriodBoundary);
                if (String.isBlank(periodBoundary) || periodBoundary == 'null') {
                    periodBoundary = 'Anniversary';
                }

                records.add(
                    '{ "referenceId": "' +
                        refId +
                        '", "record": { "attributes": { "type": "QuoteLineItem", "method": "POST", "id": "' +
                        refId +
                        '" },' +
                        '"QuoteId": "' +
                        q +
                        '",' +
                        '"Product2Id": "' +
                        p2 +
                        '",' +
                        '"PricebookEntryId": "' +
                        pbe +
                        '",' +
                        '"Quantity": ' +
                        qty +
                        ',' +
                        '"UnitPrice": ' +
                        price +
                        ',' +
                        (String.isNotBlank(billingFrequency) && billingFrequency != 'null'
                            ? '"BillingFrequency": "' + billingFrequency + '",'
                            : '') +
                        '"PeriodBoundary": "' +
                        periodBoundary +
                        '",' +
                        (String.isNotBlank(startIso) ? '"StartDate": "' + startIso + '",' : '') +
                        '"QuoteLineGroupId": "' +
                        g +
                        '"' +
                        ' } }'
                );
            }
        }

        if (ref == 0) {
            return null;
        }

        return '{' +
            '"groupRampAction": "AddProducts",' +
            '"pricingPref": "System",' +
            '"catalogRatesPref": "Skip",' +
            buildConfigurationPrefJson() +
            ',' +
            '"graph": {' +
            '"graphId": "updateQuote",' +
            '"records": [' +
            String.join(records, ',') +
            ']' +
            '}' +
            '}';
    }

    private static Integer toInteger(Object v) {
        if (v == null) {
            return null;
        }
        if (v instanceof Integer) {
            return (Integer) v;
        }
        if (v instanceof Decimal) {
            return ((Decimal) v).intValue();
        }
        try {
            return Integer.valueOf(String.valueOf(v));
        } catch (Exception e) {
            return null;
        }
    }

    private static void assertQuoteAccess(Id quoteId) {
        List<Quote> rows = [SELECT Id FROM Quote WHERE Id = :quoteId LIMIT 1];
        if (rows.isEmpty()) {
            throw new AuraHandledException('Quote not found or no access.');
        }
    }

    private static List<SegmentInput> parseSegments(String jsonStr) {
        List<SegmentInput> out = new List<SegmentInput>();
        List<Object> raw = (List<Object>) JSON.deserializeUntyped(jsonStr);
        for (Object o : raw) {
            Map<String, Object> m = (Map<String, Object>) o;
            SegmentInput s = new SegmentInput();
            s.segmentType = (String) m.get('segmentType');
            s.startDate = (String) m.get('startDate');
            s.endDate = (String) m.get('endDate');
            s.uplift = m.get('uplift') != null ? (Decimal) m.get('uplift') : null;
            s.discount = m.get('discount') != null ? (Decimal) m.get('discount') : null;
            s.name = (String) m.get('name');
            out.add(s);
        }
        return out;
    }

    private static String mapSegmentType(String uiValue) {
        if (String.isBlank(uiValue)) {
            return 'Custom';
        }
        String v = uiValue.toLowerCase();
        if (v == 'yearly') {
            return 'Yearly';
        }
        return 'Custom';
    }

    private static String buildConfigurationPrefJson() {
        return '"configurationPref": {' +
            '"configurationMethod": "Skip",' +
            '"configurationOptions": {' +
            '"validateProductCatalog": true,' +
            '"validateAmendRenewCancel": true,' +
            '"executeConfigurationRules": true,' +
            '"addDefaultConfiguration": true' +
            '}' +
            '}';
    }

    private static String buildGroupQuoteLinesPayload(Id quoteId, Id groupId, List<Id> lineIds) {
        List<String> records = new List<String>();
        records.add(
            '{ "referenceId": "' +
                String.valueOf(quoteId) +
                '", "record": { "attributes": { "type": "Quote", "method": "PATCH", "id": "' +
                String.valueOf(quoteId) +
                '" } } }'
        );
        for (Id lineId : lineIds) {
            records.add(
                '{ "referenceId": "' +
                    String.valueOf(lineId) +
                    '", "record": { "attributes": { "type": "QuoteLineItem", "method": "PATCH", "id": "' +
                    String.valueOf(lineId) +
                    '" }, "QuoteLineGroupId": "' +
                    String.valueOf(groupId) +
                    '" } }'
            );
        }
        return '{' +
            '"pricingPref": "System",' +
            '"catalogRatesPref": "Skip",' +
            buildConfigurationPrefJson() +
            ',' +
            '"graph": {' +
            '"graphId": "groupQuoteLines",' +
            '"records": [' +
            String.join(records, ',') +
            ']' +
            '}' +
            '}';
    }

    private static String buildUngroupLinesPayload(Id quoteId, List<Id> lineIds) {
        List<String> records = new List<String>();
        records.add(
            '{ "referenceId": "' +
                String.valueOf(quoteId) +
                '", "record": { "attributes": { "type": "Quote", "method": "PATCH", "id": "' +
                String.valueOf(quoteId) +
                '" } } }'
        );
        for (Id lineId : lineIds) {
            records.add(
                '{ "referenceId": "' +
                    String.valueOf(lineId) +
                    '", "record": { "attributes": { "type": "QuoteLineItem", "method": "PATCH", "id": "' +
                    String.valueOf(lineId) +
                    '" }, "QuoteLineGroupId": null } }'
            );
        }
        return '{' +
            '"pricingPref": "Skip",' +
            '"catalogRatesPref": "Skip",' +
            buildConfigurationPrefJson() +
            ',' +
            '"graph": {' +
            '"graphId": "ungroupOneTime",' +
            '"records": [' +
            String.join(records, ',') +
            ']' +
            '}' +
            '}';
    }

    private static String buildOneTimeGroupPayload(Id quoteId, List<Id> lineIds) {
        String q = String.valueOf(quoteId);
        List<String> records = new List<String>();
        records.add(
            '{ "referenceId": "refQuote", "record": { "attributes": { "type": "Quote", "method": "PATCH", "id": "' +
            q + '" } } }'
        );
        records.add(
            '{ "referenceId": "refOtGroup", "record": { "attributes": { "type": "QuoteLineGroup", "method": "POST" },' +
            '"Name": "One Time",' +
            '"QuoteId": "@{refQuote.id}"' +
            ' } }'
        );
        for (Id lineId : lineIds) {
            String lid = String.valueOf(lineId);
            records.add(
                '{ "referenceId": "' + lid + '", "record": { "attributes": { "type": "QuoteLineItem", "method": "PATCH", "id": "' +
                lid + '" }, "QuoteLineGroupId": "@{refOtGroup.id}" } }'
            );
        }
        return '{' +
            '"pricingPref": "Skip",' +
            '"catalogRatesPref": "Skip",' +
            buildConfigurationPrefJson() + ',' +
            '"graph": {' +
            '"graphId": "createOneTimeGroup",' +
            '"records": [' + String.join(records, ',') + ']' +
            '}' +
            '}';
    }

    private static String buildEditGroupPayload(
        Id quoteId,
        Id groupId,
        SegmentInput seg,
        String segmentTypeApi,
        Integer sortOrder
    ) {
        String q = String.valueOf(quoteId);
        String g = String.valueOf(groupId);
        String nameField = '';
        if (String.isNotBlank(seg.name)) {
            nameField = '"Name": "' + seg.name + '",';
        }
        return '{' +
            '"groupRampAction": "EditGroup",' +
            '"pricingPref": "System",' +
            '"graph": {' +
            '"graphId": "updateQuote",' +
            '"records": [' +
            '{ "referenceId": "' +
            q +
            '", "record": { "attributes": { "type": "Quote", "method": "PATCH", "id": "' +
            q +
            '" } } },' +
            '{ "referenceId": "' +
            g +
            '", "record": { "attributes": { "type": "QuoteLineGroup", "method": "PATCH", "id": "' +
            g +
            '" },' +
            nameField +
            '"StartDate": "' +
            seg.startDate +
            '",' +
            '"EndDate": "' +
            seg.endDate +
            '",' +
            '"SortOrder": ' +
            sortOrder +
            ',' +
            '"IsRamped": true,' +
            '"SegmentType": "' +
            segmentTypeApi +
            '"' +
            ' } }' +
            ']' +
            '}' +
            '}';
    }

    private static String buildClonePayload(Id quoteId, Id recordId, Boolean includeLineScope) {
        String payload = '{' +
            '"recordIds": ["' +
            String.valueOf(recordId) +
            '"],' +
            '"salesTransactionId": "' +
            String.valueOf(quoteId) +
            '"';
        if (includeLineScope == true) {
            payload += ',"options": { "lineScope": "AllLines" }';
        }
        payload += '}';
        return payload;
    }

    private static String buildEditRampSchedulePayload(Id quoteId, List<QuoteLineGroup> groups, List<SegmentInput> segments) {
        String q = String.valueOf(quoteId);
        List<String> records = new List<String>();
        records.add(
            '{ "referenceId": "' +
                q +
                '", "record": { "attributes": { "type": "Quote", "method": "PATCH", "id": "' +
                q +
                '" } } }'
        );
        for (Integer i = 0; i < groups.size(); i++) {
            SegmentInput seg = segments[i];
            String gid = String.valueOf(groups[i].Id);
            String nameField = '';
            if (String.isNotBlank(seg.name)) {
                nameField = '"Name": "' + seg.name + '", ';
            }
            records.add(
                '{ "referenceId": "' +
                    gid +
                    '", "record": { "attributes": { "type": "QuoteLineGroup", "method": "PATCH", "id": "' +
                    gid +
                    '" }, ' + nameField + '"StartDate": "' +
                    seg.startDate +
                    '", "EndDate": "' +
                    seg.endDate +
                    '" } }'
            );
        }
        return '{' +
            '"groupRampAction": "EditRampSchedule",' +
            '"pricingPref": "System",' +
            '"graph": {' +
            '"graphId": "updateQuote",' +
            '"records": [' +
            String.join(records, ',') +
            ']' +
            '}' +
            '}';
    }

    private static Id findPrimaryRampedGroupId(Id quoteId) {
        List<QuoteLineGroup> primaryGroups = [
            SELECT Id
            FROM QuoteLineGroup
            WHERE QuoteId = :quoteId AND IsRamped = TRUE
            ORDER BY SortOrder ASC NULLS LAST
            LIMIT 1
        ];
        if (primaryGroups.isEmpty()) {
            return null;
        }
        return primaryGroups[0].Id;
    }

    private static Id findLastRampedGroupId(Id quoteId) {
        List<QuoteLineGroup> lastGroups = [
            SELECT Id
            FROM QuoteLineGroup
            WHERE QuoteId = :quoteId AND IsRamped = TRUE
            ORDER BY SortOrder DESC NULLS LAST
            LIMIT 1
        ];
        if (lastGroups.isEmpty()) {
            return null;
        }
        return lastGroups[0].Id;
    }

    private static Id findPrimaryRampedGroupLineId(Id quoteId, Id primaryGroupId) {
        if (primaryGroupId == null) {
            return null;
        }
        List<QuoteLineItem> qlis = [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId AND QuoteLineGroupId = :primaryGroupId
            ORDER BY LineNumber NULLS LAST
            LIMIT 1
        ];
        return qlis.isEmpty() ? null : qlis[0].Id;
    }

    private static Boolean isSuccessStatus(HttpResponse res) {
        if (res == null) {
            return false;
        }
        Integer code = res.getStatusCode();
        return code >= 200 && code < 300;
    }

    private static Boolean isClonePrimarySegmentError(String body) {
        if (String.isBlank(body)) {
            return false;
        }
        String normalized = body.toLowerCase();
        return normalized.contains('isn&#39;t the primary segment') || normalized.contains('isn\'t the primary segment');
    }

    private static void throwIfNotOk(HttpResponse res) {
        if (res == null) {
            throw new AuraHandledException('Empty response from Revenue Connect.');
        }
        Integer code = res.getStatusCode();
        if (code >= 200 && code < 300) {
            return;
        }
        String body = res.getBody();
        logLong('RevConnect response body', body);
        String msg = 'Revenue Connect error (' + code + '): ' + (String.isBlank(body) ? res.getStatus() : body.left(2000));
        throw new AuraHandledException(msg);
    }


    /**
     * Applies per-segment Uplift/Discount (non-one-time lines only) and propagates each group's
     * SegmentType to its line items (all lines), across every ramped group, in a single Revenue
     * Connect call instead of up to two calls per group.
     */
    private static void applySegmentAttributesAcrossGroups(Id quoteId, List<QuoteLineGroup> orderedGroups, List<SegmentInput> segments) {
        Set<Id> allGroupIds = new Set<Id>();
        Map<Id, SegmentInput> segByGroupId = new Map<Id, SegmentInput>();
        for (Integer i = 0; i < orderedGroups.size(); i++) {
            Id gId = orderedGroups[i].Id;
            allGroupIds.add(gId);
            if (i < segments.size()) {
                segByGroupId.put(gId, segments[i]);
            }
        }
        if (allGroupIds.isEmpty()) {
            return;
        }

        Map<Id, String> segTypeByGroupId = new Map<Id, String>();
        for (QuoteLineGroup g : [SELECT Id, SegmentType FROM QuoteLineGroup WHERE Id IN :allGroupIds]) {
            if (String.isNotBlank(g.SegmentType)) {
                segTypeByGroupId.put(g.Id, g.SegmentType);
            }
        }

        Set<Id> relevantGroupIds = new Set<Id>();
        for (Id gId : allGroupIds) {
            SegmentInput seg = segByGroupId.get(gId);
            Boolean hasUpliftOrDiscount = seg != null && (seg.uplift != null || seg.discount != null);
            if (hasUpliftOrDiscount || segTypeByGroupId.containsKey(gId)) {
                relevantGroupIds.add(gId);
            }
        }
        if (relevantGroupIds.isEmpty()) {
            return;
        }

        Map<Id, List<QuoteLineItem>> linesByGroup = new Map<Id, List<QuoteLineItem>>();
        for (QuoteLineItem qli : [
            SELECT Id, QuoteLineGroupId, SellingModelType
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
              AND QuoteLineGroupId IN :relevantGroupIds
        ]) {
            if (!linesByGroup.containsKey(qli.QuoteLineGroupId)) {
                linesByGroup.put(qli.QuoteLineGroupId, new List<QuoteLineItem>());
            }
            linesByGroup.get(qli.QuoteLineGroupId).add(qli);
        }

        String q = String.valueOf(quoteId);
        List<String> records = new List<String>();
        records.add(quotePatchAnchor(q));
        Boolean anyLine = false;

        for (Id gId : relevantGroupIds) {
            List<QuoteLineItem> lines = linesByGroup.get(gId);
            if (lines == null || lines.isEmpty()) {
                continue;
            }
            records.add(groupPatchAnchor(String.valueOf(gId)));

            SegmentInput seg = segByGroupId.get(gId);
            String segType = segTypeByGroupId.get(gId);
            for (QuoteLineItem qli : lines) {
                List<String> fieldParts = new List<String>();
                if (String.isNotBlank(segType)) {
                    fieldParts.add('"SegmentType": "' + segType + '"');
                }
                Boolean isOneTime = qli.SellingModelType == 'OneTime';
                if (!isOneTime && seg != null) {
                    if (seg.uplift != null) {
                        fieldParts.add('"UnitPriceUplift": ' + seg.uplift);
                    }
                    if (seg.discount != null) {
                        fieldParts.add('"Discount": ' + seg.discount);
                    }
                }
                if (fieldParts.isEmpty()) {
                    continue;
                }
                String lid = String.valueOf(qli.Id);
                records.add(
                    '{ "referenceId": "' + lid + '", "record": { "attributes": { "type": "QuoteLineItem", "method": "PATCH", "id": "' +
                    lid + '" }, ' + String.join(fieldParts, ', ') + ' } }'
                );
                anyLine = true;
            }
        }
        if (!anyLine) {
            return;
        }

        String payload = '{' +
            '"pricingPref": "System",' +
            '"catalogRatesPref": "Skip",' +
            buildConfigurationPrefJson() + ',' +
            '"graph": {' +
            '"graphId": "applySegmentAttributes",' +
            '"records": [' + String.join(records, ',') + ']' +
            '}' +
            '}';
        throwIfNotOk(RevConnectCallout.postRev('sales-transaction/actions/place', payload));
    }

    private static void updateQuoteDates(Id quoteId, List<SegmentInput> segments) {
        if (segments.isEmpty()) {
            return;
        }
        String firstStart = segments[0].startDate;
        String lastEnd = segments[segments.size() - 1].endDate;

        Quote q = new Quote(Id = quoteId);
        if (String.isNotBlank(firstStart)) {
            q.StartDate = Date.valueOf(firstStart);
        }
        if (String.isNotBlank(lastEnd)) {
            q.EndDate = Date.valueOf(lastEnd);
        }
        // Aggregate total months across all segments
        Integer totalMonths = 0;
        for (SegmentInput seg : segments) {
            if (String.isNotBlank(seg.startDate) && String.isNotBlank(seg.endDate)) {
                Date segStart = Date.valueOf(seg.startDate);
                Date segEnd = Date.valueOf(seg.endDate);
                totalMonths += segStart.monthsBetween(segEnd);
            }
        }
        q.RLM_TermMonths__c = totalMonths;
        update q;
    }

    private static void logLong(String label, String text) {
        if (String.isBlank(text)) {
            System.debug(label + ': <empty>');
            return;
        }
        Integer chunkSize = 900;
        for (Integer i = 0; i < text.length(); i += chunkSize) {
            Integer endIdx = Math.min(i + chunkSize, text.length());
            System.debug(label + ' [' + i + '-' + (endIdx - 1) + ']: ' + text.substring(i, endIdx));
        }
    }
}
