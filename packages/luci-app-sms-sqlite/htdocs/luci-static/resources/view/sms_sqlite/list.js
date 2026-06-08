'use strict';
'require view';
'require rpc';
'require ui';
'require dom';

var callSmsGet = rpc.declare({
	object: 'sms_sqlite',
	method: 'get',
	expect: { messages: [] }
});
var callSmsDel = rpc.declare({ object: 'sms_sqlite', method: 'del', params: ['ids'] });
var callSmsSync = rpc.declare({ object: 'sms_sqlite', method: 'sync' });

return view.extend({
	load: function() {
		return callSmsGet().then(function(res) {
			return (Array.isArray(res)) ? res : [];
		}).catch(function() {
			return [];
		});
	},

	render: function(smsList) {
		var m = E('div', { class: 'cbi-map' }, [
			E('h2', { name: 'content' }, _('Inbox')),
			E('div', { class: 'cbi-section' }, [
				E('div', { style: 'text-align:right; margin-bottom:15px;' }, [
					E('button', {
						class: 'cbi-button cbi-button-action',
						click: ui.createHandlerFn(this, function() {
							return callSmsSync().then(function(res) {
								if (res && res.status === 'busy') {
									ui.addNotification(null, E('p', _('Collector is already running in the background. Try again later.')));
								}
								location.reload();
							});
						})
					}, _('Fetch SMS now')),
					' ',
					E('button', {
						class: 'cbi-button cbi-button-remove',
						click: ui.createHandlerFn(this, function() {
							var ids = Array.from(document.querySelectorAll('.sms-cb:checked')).map(function(cb) { return cb.value; }).join(',');
							if (!ids) return;
							if (confirm(_('Delete selected messages?'))) {
								return callSmsDel(ids).then(function() {
									location.reload();
								});
							}
						})
					}, _('Delete selected'))
				]),
				E('table', { class: 'table cbi-section-table' }, [
					E('tr', { class: 'tr table-titles' }, [
						E('th', { class: 'th', style: 'width:5%;' }, E('input', {
							type: 'checkbox',
							click: function(e) {
								document.querySelectorAll('.sms-cb').forEach(function(cb) { cb.checked = e.target.checked; });
							}
						})),
					E('th', { class: 'th', style: 'width:15%;' }, _('Sender')),
					E('th', { class: 'th', style: 'width:20%;' }, _('Date')),
					E('th', { class: 'th', style: 'width:60%;' }, _('Message'))
					])
				])
			])
		]);

		var table = m.querySelector('table');

		if (!Array.isArray(smsList) || smsList.length === 0) {
			table.appendChild(E('tr', { class: 'tr cbi-rowstyle-1' }, [
				E('td', { class: 'td', colspan: 4, style: 'text-align:center;' }, _('No messages'))
			]));
		} else {
			smsList.forEach(function(sms, i) {
				var d = sms.receive_date || '';
				var match = d.match(/(\d+)\/(\d+)\/(\d+),(\d+:\d+:\d+)/);
				var dateStr = match ? (match[3] + '.' + match[2] + '.20' + match[1] + ' ' + match[4]) : d;

				table.appendChild(E('tr', { class: 'tr cbi-rowstyle-' + (i % 2 === 0 ? '1' : '2') }, [
					E('td', { class: 'td' }, E('input', { type: 'checkbox', class: 'sms-cb', value: String(sms.id) })),
					E('td', { class: 'td' }, sms.sender),
					E('td', { class: 'td' }, dateStr),
					E('td', { class: 'td' }, sms.message)
				]));
			});
		}

		return m;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
