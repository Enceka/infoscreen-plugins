'use strict';

const $ = (id) => document.getElementById(id);
const DIGIT_KEYS = {
	2: 'abc', 3: 'def', 4: 'ghi', 5: 'jkl', 6: 'mno',
	7: 'pqrs', 8: 'tuv', 9: 'wxyz'
};
const DIGIT_OF = {};
for (const key of Object.keys(DIGIT_KEYS)) for (const letter of DIGIT_KEYS[key]) DIGIT_OF[letter] = key;
const PUNCTUATION = ['，', '。', '？', '！', '、', '：', '；', '（', '）', '－'];
const ENGLISH = { 1: '.,?!', 2: 'abc', 3: 'def', 4: 'ghi', 5: 'jkl', 6: 'mno', 7: 'pqrs', 8: 'tuv', 9: 'wxyz' };
const MODES = ['zh', 'en', 'num'];
const WORD_LIMIT = 8;
const MULTITAP_MS = 850;

const WORDS = PINYIN9_ENTRIES.map((raw, order) => {
	const entry = typeof raw === 'string'
		? (() => { const i = raw.lastIndexOf(' '); return { pinyin: raw.slice(0, i), text: raw.slice(i + 1) }; })()
		: raw;
	return {
		pinyin: entry.pinyin,
		text: entry.text,
		order,
		signature: [...entry.pinyin.toLowerCase()].map((letter) => DIGIT_OF[letter] ?? '').join('')
	};
}).filter((entry) => entry.signature && entry.signature.length > 0)
	.filter((entry, index, all) => all.findIndex((other) => other.signature === entry.signature && other.text === entry.text) === index);

const state = {
	mode: 'zh',
	text: '',
	buffer: '',
	candidate: 0,
	punctKey: null,
	punctIndex: 0,
	punctAt: 0,
	englishKey: null,
	englishIndex: 0,
	englishAt: 0,
	timer: 0
};

function tr(zh, en) { return e5.t({ zh, en }); }

function appendText(value) {
	if (!value) return;
	const text = String(value);
	state.text = [...state.text, ...text].slice(-2000).join('');
	e5.input(text);
}

function hasPunctuation() { return state.punctKey !== null; }

function commitPunctuation() {
	if (!hasPunctuation()) return;
	appendText(PUNCTUATION[state.punctIndex]);
	state.punctKey = null;
	state.punctIndex = 0;
	state.punctAt = 0;
}

function commitEnglish() {
	if (state.englishKey === null) return;
	const letters = ENGLISH[state.englishKey] || '';
	appendText(letters[state.englishIndex] || '');
	state.englishKey = null;
	state.englishIndex = 0;
	state.englishAt = 0;
}

function clearComposition() {
	state.buffer = '';
	state.candidate = 0;
}

function candidateList() {
	if (state.mode !== 'zh' || !state.buffer) return [];
	return WORDS.filter((entry) => entry.signature.startsWith(state.buffer)).sort((a, b) => {
		const ae = a.signature === state.buffer ? 0 : 1;
		const be = b.signature === state.buffer ? 0 : 1;
		return ae - be || a.order - b.order;
	});
}

function commitCandidate(index = state.candidate) {
	if (!state.buffer) return false;
	const list = candidateList();
	const chosen = list[index] || list[0];
	appendText(chosen ? chosen.text : state.buffer);
	clearComposition();
	return true;
}

function finishPending() {
	if (state.mode === 'zh') {
		if (state.buffer) commitCandidate();
		commitPunctuation();
	} else if (state.mode === 'en') {
		commitEnglish();
	}
}

function changeMode(mode) {
	if (!MODES.includes(mode) || mode === state.mode) return;
	finishPending();
	state.mode = mode;
	state.candidate = 0;
	render();
}

function cycleMode() {
	const next = MODES[(MODES.indexOf(state.mode) + 1) % MODES.length];
	changeMode(next);
}

function scheduleTimer() {
	const token = ++state.timer;
	setTimeout(() => {
		if (token !== state.timer) return;
		let changed = false;
		if (state.punctKey !== null && Date.now() - state.punctAt >= MULTITAP_MS) {
			commitPunctuation(); changed = true;
		}
		if (state.englishKey !== null && Date.now() - state.englishAt >= MULTITAP_MS) {
			commitEnglish(); changed = true;
		}
		if (changed) render();
	}, MULTITAP_MS + 20);
}

function punctuationInput() {
	const now = Date.now();
	if (state.punctKey === '1' && now - state.punctAt < MULTITAP_MS) {
		state.punctIndex = (state.punctIndex + 1) % PUNCTUATION.length;
	} else {
		commitPunctuation();
		state.punctKey = '1';
		state.punctIndex = 0;
	}
	state.punctAt = now;
	scheduleTimer();
	render();
}

function englishInput(key) {
	if (key === '0') {
		commitEnglish(); appendText(' '); render(); return;
	}
	if (key === '#') {
		commitEnglish(); appendText('#'); render(); return;
	}
	const letters = ENGLISH[key];
	if (!letters) return;
	const now = Date.now();
	if (state.englishKey === key && now - state.englishAt < MULTITAP_MS) {
		state.englishIndex = (state.englishIndex + 1) % letters.length;
	} else {
		commitEnglish();
		state.englishKey = key;
		state.englishIndex = 0;
	}
	state.englishAt = now;
	scheduleTimer();
	render();
}

function chineseInput(key) {
	if (key === '1') { commitCandidate(); punctuationInput(); return; }
	if (key === '0') {
		commitCandidate(); commitPunctuation(); appendText(' '); render(); return;
	}
	if (key === '#') {
		if (state.buffer) commitCandidate();
		else { commitPunctuation(); appendText('#'); }
		render(); return;
	}
	if (!DIGIT_KEYS[key]) return;
	commitPunctuation();
	state.buffer += key;
	state.candidate = 0;
	render();
}

function numberInput(key) {
	if (key === '*') { cycleMode(); return; }
	appendText(key);
	render();
}

function inputDigit(key) {
	if (key === '*') { cycleMode(); return; }
	if (state.mode === 'zh') chineseInput(key);
	else if (state.mode === 'en') englishInput(key);
	else numberInput(key);
}

function moveCandidate(delta) {
	const list = candidateList();
	if (!list.length) return false;
	state.candidate = (state.candidate + delta + list.length) % list.length;
	renderCandidates(list);
	return true;
}

function handleKey(key) {
	if (key.kind === 'digit') { inputDigit(key.key); return true; }
	if (key.kind === 'ok') {
		if (state.mode === 'zh' && state.buffer) commitCandidate();
		else if (state.mode === 'zh' && hasPunctuation()) commitPunctuation();
		else if (state.mode === 'en') commitEnglish();
		render(); return true;
	}
	if (key.kind === 'up' || key.kind === 'left') { moveCandidate(-1); return true; }
	if (key.kind === 'down' || key.kind === 'right') { moveCandidate(1); return true; }
	return false;
}

function backspace() {
	if (state.buffer) {
		state.buffer = state.buffer.slice(0, -1); state.candidate = 0; render(); return true;
	}
	if (hasPunctuation()) { state.punctKey = null; render(); return true; }
	if (state.englishKey !== null) { state.englishKey = null; render(); return true; }
	if (state.text) { state.text = [...state.text].slice(0, -1).join(''); e5.inputBackspace(); render(); return true; }
	return false;
}

function renderCandidates(list = candidateList()) {
	const box = $('candidates');
	box.replaceChildren();
	if (state.mode !== 'zh' || (!state.buffer && !hasPunctuation())) return;
	if (hasPunctuation()) {
		const button = document.createElement('button');
		button.type = 'button'; button.className = 'candidate active';
		button.textContent = PUNCTUATION[state.punctIndex];
		button.addEventListener('click', () => { commitPunctuation(); render(); });
		box.append(button);
		return;
	}
	const start = Math.max(0, Math.min(state.candidate - 3, Math.max(0, list.length - WORD_LIMIT)));
	list.slice(start, start + WORD_LIMIT).forEach((entry, offset) => {
		const index = start + offset;
		const button = document.createElement('button');
		button.type = 'button'; button.className = `candidate${index === state.candidate ? ' active' : ''}`;
		button.textContent = entry.text;
		button.title = entry.pinyin;
		button.addEventListener('click', () => { commitCandidate(index); render(); });
		box.append(button);
	});
	if (!list.length) {
		const empty = document.createElement('span');
		empty.className = 'candidate more';
		empty.textContent = tr('无候选，可按确认输入数字', 'No match; OK enters the digits');
		box.append(empty);
	} else if (list.length > start + WORD_LIMIT) {
		const more = document.createElement('span');
		more.className = 'candidate more';
		more.textContent = tr('上下选词', 'up/down');
		box.append(more);
	}
}

function render() {
	$('text').textContent = state.text;
	$('text').dataset.placeholder = tr('请输入文字', 'Type something');
	let composition = '';
	if (state.mode === 'zh' && state.buffer) composition = `${state.buffer}  ${state.buffer.split('').map((key) => DIGIT_KEYS[key] || '').join('')}`;
	if (state.mode === 'zh' && hasPunctuation()) composition = PUNCTUATION[state.punctIndex];
	if (state.mode === 'en' && state.englishKey !== null) composition = ENGLISH[state.englishKey][state.englishIndex];
	$('composition').textContent = composition;
	$('mode-hint').textContent = state.mode === 'zh' ? tr('中文', 'Chinese') : state.mode === 'en' ? 'ABC' : '123';
	for (const button of document.querySelectorAll('[data-mode]')) {
		button.classList.toggle('active', button.dataset.mode === state.mode);
		button.textContent = button.dataset.mode === 'zh' ? tr('中文', 'Chinese') : button.dataset.mode === 'en' ? 'ABC' : '123';
	}
	$('title').textContent = tr('九键输入法', 'Nine-key Chinese');
	$('space').textContent = tr('空格', 'Space');
	$('confirm').textContent = tr('确认', 'OK');
	const targetHint = e5.inputAvailable ? tr(' · 已连接当前输入框', ' · linked to input') : '';
	$('help').textContent = state.mode === 'zh'
		? tr('2-9 拼音 · 上下选词 · * 切换模式 · # 确认', '2-9 pinyin · up/down choose · * mode · # choose')
		: state.mode === 'en'
			? tr('重复按键选择字母 · * 切换模式 · 返回退格', 'tap a key repeatedly for a letter · * mode · backspace')
			: tr('数字直输 · * 切换模式 · 返回退格', 'digits · * mode · backspace');
	$('help').textContent += targetHint;
	renderCandidates();
}

document.querySelectorAll('[data-key]').forEach((button) => button.addEventListener('click', () => inputDigit(button.dataset.key)));
document.querySelectorAll('[data-mode]').forEach((button) => button.addEventListener('click', () => changeMode(button.dataset.mode)));
$('space').addEventListener('click', () => { finishPending(); appendText(' '); render(); });
$('confirm').addEventListener('click', () => { finishPending(); render(); });
$('backspace').addEventListener('click', backspace);
e5.onKey(handleKey);
e5.onBack(() => backspace());
e5.onLang(render);
e5.onInputTarget(render);
e5.onInputResult((result) => { if (!result.ok) e5.toast(tr('当前输入框不可用', 'The input target is unavailable')); });
render();
