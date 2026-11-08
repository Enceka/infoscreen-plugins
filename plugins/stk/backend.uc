'use strict';
import { readfile } from 'fs';

// The STK backend: every request re-reads the modem's URC rings and the state
// the previous request left in /tmp/e5-stk.  stk.uc holds the protocol.
return function(ctx) {
	// The LVGL interface runs its own SIM toolkit on the same rings, and polls
	// the notifications through this backend all the same.
	if (index(readfile('/usr/libexec/e5-infoscreen/session') ?? '', 'exec /usr/libexec/e5-infoscreen/ui') >= 0)
		return {};
	let stk = loadfile('/usr/share/e5-infoscreen/www/plugins/stk/stk.uc', { raw_mode: true })()(ctx);

	function fail(error, code) {
		return { status: code ?? 400, type: 'application/json', body: sprintf('%J', { ok: false, error }) };
	}

	// The page redraws from the reply, so an action answers with the state it left.
	function done(r) {
		return r?.ok === false ? fail(r.error ?? 'SIM toolkit is busy', 409) : stk.status();
	}

	function slot_of(body) {
		let v = body?.slot;
		if (v == null) return 0;
		return match(`${v}`, /^[01]$/) ? int(v) : null;
	}

	function flag_of(v) {
		if (type(v) == 'bool') return v;
		if (type(v) == 'int' || type(v) == 'double') return int(v) != 0;
		return null;
	}

	function item_of(v) {
		if (type(v) != 'int' && type(v) != 'double') return null;
		let n = int(v);
		return n >= 0 && n < 256 && n == v ? n : null;
	}

	function text_of(v) {
		return type(v) == 'string' && length(v) <= 512 ? v : null;
	}

	function slot_route(req, fn) {
		let slot = slot_of(req.body);
		if (slot == null) return fail('Invalid SIM slot');
		return done(fn(slot));
	}

	return {
		'GET /status': function() {
			return stk.status();
		},
		'GET /notifications': function() {
			return stk.notifications();
		},
		'POST /open': function(req) {
			if (req.body?.slot == null) return done(stk.open(null));
			return slot_route(req, slot => stk.open(slot));
		},
		'POST /close': function() {
			return stk.close();
		},
		'POST /choose': function(req) {
			let slot = slot_of(req.body);
			if (slot == null) return fail('Invalid SIM slot');
			let item = item_of(req.body?.item_id);
			if (item == null) return fail('Invalid item id');
			return done(stk.choose(slot, item));
		},
		'POST /input': function(req) {
			let slot = slot_of(req.body);
			if (slot == null) return fail('Invalid SIM slot');
			let text = text_of(req.body?.text);
			if (text == null) return fail('Invalid text');
			return done(stk.input(slot, text));
		},
		'POST /yesno': function(req) {
			let slot = slot_of(req.body);
			if (slot == null) return fail('Invalid SIM slot');
			let yes = flag_of(req.body?.yes);
			if (yes == null) return fail('Invalid answer');
			return done(stk.yesno(slot, yes));
		},
		'POST /ack': function(req) {
			return slot_route(req, slot => stk.ack(slot));
		},
		'POST /call': function(req) {
			let slot = slot_of(req.body);
			if (slot == null) return fail('Invalid SIM slot');
			let accept = flag_of(req.body?.accept);
			if (accept == null) return fail('Invalid answer');
			return done(stk.call(slot, accept));
		},
		'POST /back': function(req) {
			return slot_route(req, slot => stk.back(slot));
		},
		'POST /retry': function(req) {
			return slot_route(req, slot => stk.retry(slot));
		},
		'POST /clear-cache': function() {
			return done(stk.clear_cache());
		},
		'POST /enabled': function(req) {
			let on = flag_of(req.body?.enabled);
			if (on == null) return fail('Invalid setting');
			return done(stk.set_enabled(on));
		}
	};
};
