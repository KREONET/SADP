const $ = (id) => document.getElementById(id);
let current = null;

function status(message, error = false) {
  $('status').textContent = message;
  $('status').classList.toggle('error', error);
}

function stopMicrophone(session) {
  session.stream?.getTracks().forEach((track) => track.stop());
  session.recorder?.disconnect();
  session.source?.disconnect();
  session.filter?.disconnect();
  if (session.context && session.context.state !== 'closed') void session.context.close().catch(() => {});
}

function cleanup(session) {
  clearTimeout(session.timer);
  stopMicrophone(session);
  if (session.ws && session.ws.readyState < WebSocket.CLOSING) session.ws.close();
  if (current === session) {
    current = null;
    $('start').disabled = false;
    $('stop').disabled = true;
    $('token').disabled = false;
  }
}

function fail(session, message) {
  if (current !== session) return;
  status(message, true);
  cleanup(session);
}

function appendTranslation(data) {
  if (!data.text) return;
  $('empty').hidden = true;
  const row = document.createElement('article');
  row.className = 'result';
  const text = document.createElement('p');
  text.lang = 'en';
  text.textContent = data.text;
  const details = document.createElement('small');
  details.textContent = `${(data.start_ms / 1000).toFixed(1)}–${(data.end_ms / 1000).toFixed(1)}초 · 처리 ${(data.processing_ms / 1000).toFixed(2)}초`;
  row.append(text, details);
  $('results').append(row);
  // 장시간 사용해도 브라우저가 전체 대화 DOM을 계속 보유하지 않게 한다.
  while ($('results').children.length > 200) $('results').firstElementChild.remove();
}

const errors = {
  unauthorized: 'API 토큰을 확인해 주세요.', busy: '서버가 사용 중입니다. 잠시 후 다시 시작해 주세요.',
  overloaded: '번역 처리가 입력 속도를 따라가지 못했습니다. 잠시 후 다시 시작해 주세요.',
  idle_timeout: '음성 입력이 끊겨 연결을 종료했습니다.', timeout: '연결 제한 시간이 지났습니다. 다시 시작해 주세요.',
  inference_failed: '서버의 번역 처리에 실패했습니다. 서버 상태를 확인해 주세요.',
  audio_rate_exceeded: '오디오 전송이 지연되어 연결을 종료했습니다. 다시 시작해 주세요.',
};

$('controls').addEventListener('submit', async (event) => {
  event.preventDefault();
  if (current) return;
  if (!window.isSecureContext || !navigator.mediaDevices?.getUserMedia) {
    status('마이크를 사용하려면 HTTPS 또는 localhost로 접속해 주세요.', true);
    return;
  }
  const session = { state: 'starting' };
  current = session;
  $('start').disabled = true;
  $('stop').disabled = false;
  $('token').disabled = true;
  status('마이크 권한을 확인하고 서버에 연결하고 있습니다…');
  try {
    session.context = new AudioContext();
    await session.context.resume();
    if (current !== session) return;
    session.stream = await navigator.mediaDevices.getUserMedia({ audio: {
      channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true,
    } });
    if (current !== session) { stopMicrophone(session); return; }
    session.stream.getAudioTracks()[0].addEventListener('ended', () => {
      if (session.state === 'running') fail(session, '마이크 연결이 끊겼습니다. 다시 시작해 주세요.');
    });
    await session.context.audioWorklet.addModule('/static/recorder.js');
    if (current !== session) return;
    session.ws = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/v1/translate`);
    session.timer = setTimeout(() => fail(session, '서버 연결 시간이 초과되었습니다.'), 15000);
    session.ws.onopen = () => {
      if (current !== session) { session.ws.close(); return; }
      session.ws.send(JSON.stringify({ type: 'start', token: $('token').value, sample_rate: 16000, format: 'pcm_s16le' }));
    };
    session.ws.onmessage = ({ data }) => {
      if (current !== session) return;
      let message;
      try { message = JSON.parse(data); } catch { fail(session, '서버 응답 형식이 올바르지 않습니다.'); return; }
      if (message.type === 'ready') {
        clearTimeout(session.timer);
        session.source = session.context.createMediaStreamSource(session.stream);
        session.filter = session.context.createBiquadFilter();
        session.filter.type = 'lowpass';
        session.filter.frequency.value = 7000;
        session.recorder = new AudioWorkletNode(session.context, 'pcm-recorder', { channelCount: 1, channelCountMode: 'explicit' });
        session.recorder.onprocessorerror = () => fail(session, '마이크 오디오 처리에 실패했습니다.');
        session.recorder.port.onmessage = ({ data: packet }) => {
          if (current !== session || session.ws.readyState !== WebSocket.OPEN) return;
          if (packet.type === 'pcm') {
            if (session.ws.bufferedAmount > 32000) { fail(session, '네트워크가 느려 번역을 중지했습니다. 다시 연결해 주세요.'); return; }
            session.ws.send(packet.buffer);
          } else if (packet.type === 'flushed') {
            session.ws.send(JSON.stringify({ type: 'stop' }));
            stopMicrophone(session);
          }
        };
        session.source.connect(session.filter).connect(session.recorder).connect(session.context.destination);
        session.state = 'running';
        status('듣고 있습니다. 한국어로 말해 주세요.');
      } else if (message.type === 'translation') {
        appendTranslation(message);
      } else if (message.type === 'stopped') {
        status('번역이 종료되었습니다.');
        cleanup(session);
      } else if (message.type === 'error') {
        fail(session, errors[message.code] || `연결 오류: ${message.code}`);
      }
    };
    session.ws.onerror = () => fail(session, '서버에 연결할 수 없습니다. 주소와 서버 상태를 확인해 주세요.');
    session.ws.onclose = () => {
      if (current === session) fail(session, '서버 연결이 종료되었습니다. 마지막 번역이 완료되지 않았을 수 있습니다.');
    };
  } catch (error) {
    fail(session, error.name === 'NotAllowedError' ? '브라우저에서 마이크 접근을 허용해 주세요.' : '마이크를 시작할 수 없습니다. 장치와 브라우저 설정을 확인해 주세요.');
  }
});

$('stop').addEventListener('click', () => {
  const session = current;
  if (!session) return;
  if (session.state !== 'running') {
    cleanup(session);
    status('연결을 취소했습니다.');
    return;
  }
  session.state = 'stopping';
  $('stop').disabled = true;
  status('남은 음성을 번역하고 있습니다…');
  session.timer = setTimeout(() => fail(session, '마지막 번역 대기 시간이 초과되었습니다. 결과가 누락되었을 수 있습니다.'), 60000);
  session.recorder.port.postMessage({ type: 'flush' });
});

$('clear').addEventListener('click', () => { $('results').replaceChildren(); $('empty').hidden = false; });
window.addEventListener('pagehide', () => { if (current) cleanup(current); });
