import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import getQuoteRampContext from '@salesforce/apex/QuoteRampController.getQuoteRampContext';
import applyGroupRamp from '@salesforce/apex/QuoteRampController.applyGroupRamp';

function addMonthsInclusiveEnd(isoDateStr, monthsToAdd) {
    if (!isoDateStr || monthsToAdd == null || monthsToAdd < 1) {
        return isoDateStr;
    }
    const [y, m, d] = isoDateStr.split('-').map((n) => parseInt(n, 10));
    const start = new Date(Date.UTC(y, m - 1, d));
    const end = new Date(start.getTime());
    end.setUTCMonth(end.getUTCMonth() + monthsToAdd);
    end.setUTCDate(end.getUTCDate() - 1);
    return end.toISOString().slice(0, 10);
}

function addDays(isoDateStr, daysToAdd) {
    if (!isoDateStr || daysToAdd == null) {
        return isoDateStr;
    }
    const [y, m, d] = isoDateStr.split('-').map((n) => parseInt(n, 10));
    const dt = new Date(Date.UTC(y, m - 1, d));
    dt.setUTCDate(dt.getUTCDate() + daysToAdd);
    return dt.toISOString().slice(0, 10);
}

export default class QuoteRampBuilder extends LightningElement {
    @api recordId;

    @track context;
    @track error;
    @track successMessage;
    @track progressStage;
    @track uiMode = 'form';

    /** Number of ramp segments (groups), 1–12 */
    @track segmentCount = 2;

    /** Type applies to all segments. */
    @track segmentType = 'Custom';


    /** @type {{ startDate: string; months: number; endDate: string; manualEnd: boolean; key: string }[]} */
    @track segments = [];

    applying = false;
    stageTimerId;

    @wire(getQuoteRampContext, { quoteId: '$recordId' })
    wiredContext({ data, err }) {
        if (data) {
            this.context = data;
            this.error = undefined;
            this.initSegmentsIfNeeded();
        } else if (err) {
            this.error = err;
            this.context = undefined;
        }
    }

    initSegmentsIfNeeded() {
        const n = Math.max(1, Math.min(12, Number(this.segmentCount) || 1));
        const next = [];
        const today = new Date();
        const pad = (x) => String(x).padStart(2, '0');
        const defaultStart = `${today.getFullYear()}-${pad(today.getMonth() + 1)}-${pad(today.getDate())}`;
        for (let i = 0; i < n; i++) {
            const prev = this.segments[i];
            let startDate = prev?.startDate || defaultStart;
            if (i > 0) {
                const prevEnd = next[i - 1]?.endDate;
                if (prevEnd) {
                    startDate = addDays(prevEnd, 1);
                }
            }
            const months = prev?.months ?? 12;
            const manualEnd = prev?.manualEnd || false;
            let endDate = prev?.endDate;
            if (!manualEnd || !endDate) {
                endDate = addMonthsInclusiveEnd(startDate, months);
            }
            const prefix = this.segmentType === 'Yearly' ? 'Year' : 'Term';
            next.push({
                key: `seg-${i}`,
                segmentIndex: `${i + 1}`,
                name: prev?.name || `${prefix} ${i + 1}`,
                startDate,
                months,
                endDate,
                manualEnd,
                uplift: prev?.uplift ?? null,
                discount: prev?.discount ?? null
            });
        }
        this.segments = next;
    }

    normalizeSegmentTimeline(seedSegments) {
        const normalized = [];
        for (let i = 0; i < seedSegments.length; i++) {
            const row = { ...seedSegments[i] };
            if (i > 0) {
                const prevEnd = normalized[i - 1]?.endDate;
                if (prevEnd) {
                    row.startDate = addDays(prevEnd, 1);
                }
            }
            if (!row.manualEnd || !row.endDate) {
                row.endDate = addMonthsInclusiveEnd(row.startDate, row.months);
            }
            row.key = `seg-${i}`;
            row.segmentIndex = `${i + 1}`;
            normalized.push(row);
        }
        this.segments = normalized;
    }

    get segmentTypeOptions() {
        return [
            { label: 'Custom', value: 'Custom' },
            { label: 'Yearly', value: 'Yearly' }
        ];
    }

    /** Flat tree of lines eligible for ramp inclusion (PricingTerm > 0). */
    get rampEligibleLineRows() {
        const lines = this.context?.lines || [];
        const eligible = lines.filter((l) => Number(l.pricingTerm) > 0);
        const eligibleById = new Map(eligible.map((l) => [l.id, l]));
        const roots = eligible.filter((l) => !l.parentQuoteLineItemId || !eligibleById.has(l.parentQuoteLineItemId));
        const childrenByParent = new Map();
        eligible.forEach((line) => {
            if (!line.parentQuoteLineItemId || !eligibleById.has(line.parentQuoteLineItemId)) {
                return;
            }
            if (!childrenByParent.has(line.parentQuoteLineItemId)) {
                childrenByParent.set(line.parentQuoteLineItemId, []);
            }
            childrenByParent.get(line.parentQuoteLineItemId).push(line);
        });
        childrenByParent.forEach((arr) => arr.sort((a, b) => (a.lineNumber || 0) - (b.lineNumber || 0)));
        const rows = [];

        const visit = (line, depth) => {
            rows.push({
                ...line,
                depth,
                indentStyle: `margin-left:${depth * 1.25}rem`,
                displayLabel:
                    line.lineNumber != null
                        ? `${line.productName} (line ${line.lineNumber})`
                        : line.productName
            });
            (childrenByParent.get(line.id) || []).forEach((c) => visit(c, depth + 1));
        };

        roots.sort((a, b) => (a.lineNumber || 0) - (b.lineNumber || 0));
        roots.forEach((r) => visit(r, 0));
        if (rows.length === 0) {
            eligible.forEach((l) =>
                rows.push({
                    ...l,
                    depth: 0,
                    indentStyle: 'margin-left:0',
                    displayLabel:
                        l.lineNumber != null ? `${l.productName} (line ${l.lineNumber})` : l.productName
                })
            );
        }
        return rows;
    }

    get showRampProductSelection() {
        return (Number(this.segmentCount) || 1) > 1;
    }

    get hasRampEligibleProducts() {
        return this.rampEligibleLineRows.length > 0;
    }

    handleSegmentCountChange(e) {
        this.successMessage = null;
        this.progressStage = null;
        this.uiMode = 'form';
        this.segmentCount = parseInt(e.target.value, 10) || 1;
        this.initSegmentsIfNeeded();
    }

    handleGlobalSegmentTypeChange(e) {
        this.successMessage = null;
        this.progressStage = null;
        this.uiMode = 'form';
        const newType = e.detail.value || 'Custom';
        const oldType = this.segmentType;
        this.segmentType = newType;
        if (oldType !== newType) {
            const prefix = newType === 'Yearly' ? 'Year' : 'Term';
            this.segments = this.segments.map((seg, i) => ({
                ...seg,
                name: `${prefix} ${i + 1}`
            }));
        }
    }

    handleSegmentField(e) {
        this.successMessage = null;
        this.progressStage = null;
        this.uiMode = 'form';
        const idx = parseInt(e.target.dataset.index, 10);
        const field = e.target.dataset.field;
        if (Number.isNaN(idx) || !field) {
            return;
        }
        const row = { ...this.segments[idx] };
        if (field === 'startDate') {
            row.startDate = e.target.value;
            if (!row.manualEnd) {
                row.endDate = addMonthsInclusiveEnd(row.startDate, row.months);
            }
        } else if (field === 'months') {
            row.months = parseInt(e.target.value, 10) || 1;
            if (!row.manualEnd) {
                row.endDate = addMonthsInclusiveEnd(row.startDate, row.months);
            }
        } else if (field === 'endDate') {
            row.endDate = e.target.value;
            row.manualEnd = true;
        } else if (field === 'name') {
            row.name = e.target.value || '';
        } else if (field === 'uplift') {
            row.uplift = e.target.value === '' || e.target.value == null ? null : parseFloat(e.target.value);
        } else if (field === 'discount') {
            row.discount = e.target.value === '' || e.target.value == null ? null : parseFloat(e.target.value);
        }
        const copy = [...this.segments];
        copy[idx] = row;
        this.normalizeSegmentTimeline(copy);
    }


    async handleApply() {
        this.successMessage = null;
        this.progressStage = null;
        this.uiMode = 'form';
        if (!this.recordId) {
            this.toast('Missing data', 'Quote Id is required.', 'error');
            return;
        }
        const payload = this.segments.map((s) => ({
            segmentType: this.segmentType,
            startDate: s.startDate,
            endDate: s.endDate,
            uplift: s.uplift,
            discount: s.discount,
            name: s.name || null
        }));

        const additional = {};
        const allEligibleIds = this.rampEligibleLineRows.map((r) => r.id);
        if (allEligibleIds.length) {
            for (let segNum = 2; segNum <= this.segmentCount; segNum++) {
                additional[segNum] = [...allEligibleIds];
            }
        }

        this.applying = true;
        this.uiMode = 'processing';
        this.startProgressStages();
        // Give the browser a tick to render processing view before callout work begins.
        await new Promise((resolve) => {
            window.setTimeout(resolve, 0);
        });
        try {
            await applyGroupRamp({
                quoteId: this.recordId,
                segmentsJson: JSON.stringify(payload),
                additionalSegmentLinesJson: JSON.stringify(additional)
            });
            this.stopProgressStages();
            this.progressStage = 'Success!';
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this.successMessage = 'Ramp schedule was applied successfully.';
            this.uiMode = 'success';
            this.toast('Success', this.successMessage, 'success');
        } catch (ex) {
            this.stopProgressStages();
            const msg = ex?.body?.message || ex?.message || 'Unknown error';
            this.uiMode = 'form';
            this.toast('Ramp failed', msg, 'error');
        } finally {
            this.applying = false;
        }
    }

    startProgressStages() {
        this.stopProgressStages();
        this.progressStage = 'Thinking...';
        const stages = ['Planning...', 'Building...'];
        let idx = 0;
        this.stageTimerId = setInterval(() => {
            if (!this.applying || idx >= stages.length) {
                this.stopProgressStages();
                return;
            }
            this.progressStage = stages[idx];
            idx += 1;
        }, 1200);
    }

    stopProgressStages() {
        if (this.stageTimerId) {
            clearInterval(this.stageTimerId);
            this.stageTimerId = null;
        }
    }

    get showProcessingView() {
        return this.uiMode === 'processing';
    }

    get showSuccessView() {
        return this.uiMode === 'success';
    }

    get showBuilderView() {
        return this.uiMode === 'form';
    }

    handleCloseNotice() {
        this.successMessage = null;
        this.progressStage = null;
        this.uiMode = 'form';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}