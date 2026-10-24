"""Real native admission fingerprints and committed result replay across adapter restarts."""
import json
import os
from datetime import datetime, timezone
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from gateway.platforms.event import MessageEvent
from hermes_state import SessionDB
from ..adapter import OrialisAdapter
from .. import adapter as adapter_module
from . import test_native_transport as transport_tests

_SUPPORTED = adapter_module._native_receipts_available()
if _SUPPORTED:
    from gateway.session_envelope import prepare_native
    from gateway.session_ingress_context import native_callback
    from hermes_state_runtime import (admit_session_input, begin_runtime_epoch, claim_session_input,
        settle_session_input, find_session_admission, RuntimeStoreError)


@unittest.skipUnless(_SUPPORTED, 'Installed Hermes has no native admission receipt/replay API')
class NativeRetryTests(unittest.IsolatedAsyncioTestCase):
    setUp = transport_tests.NativeTransportTests.setUp

    async def asyncSetUp(self):
        self.adapter._orialis = replace(self.adapter._orialis, device_id='JXCZ_TEST_Hermes')
        self.db = SessionDB(Path(self.home.name)/'state.db')
        self.db.create_session('owned', 'orialis')
        self.db.create_session('other', 'orialis')
        self.epoch = begin_runtime_epoch(self.db, instance_id='native-retry-test')
        self.authority = SimpleNamespace(db=self.db, epoch=self.epoch)
        self.runner = SimpleNamespace(config=SimpleNamespace(multiplex_profiles=False),
            session_authority=self.authority, adapters={self.adapter.platform:self.adapter},
            _native_transport_homes={None:Path(self.home.name).resolve()},
            session_store=SimpleNamespace(_generate_session_key=lambda s:'route:'+s.chat_id,
                lookup_by_session_key=lambda route:SimpleNamespace(session_id='owned' if route=='route:orialis:chat' else 'other')),
            _adapter_profile_for_source=lambda source:None,
            _adapter_credential_fingerprint=lambda adapter:'fixture-credential-identity',
            _transport_owner=lambda source:(self.adapter,None),
            _adapter_for_source=lambda source:self.adapter,
            _adapter_flag=lambda *args:False,
            _profile_name_for_source=lambda *args, **kwargs:None,
            _is_user_authorized_for_source=lambda source, **kwargs:source.user_id==self.adapter._orialis.device_id)
        self.adapter.gateway_runner = self.runner

    async def asyncTearDown(self):
        self.db.close()
        # Hermes' native test fixture releases probe handles only after closing its private DB.
        import hermes_state_dbfile as dbfile
        with dbfile._HEADER_PROBE_LOCK:
            for key in list(dbfile._HEADER_PROBE_FDS):
                if Path(key).is_relative_to(Path(self.home.name)):
                    fd, _, _ = dbfile._HEADER_PROBE_FDS.pop(key)
                    os.close(fd)
        await transport_tests.NativeTransportTests.asyncTearDown(self)

    def event(self, request_id='stable', text='original', timestamp=None, conversation='chat'):
        source=self.adapter.build_source(chat_id='orialis:'+conversation,chat_name=conversation,chat_type='dm',
            user_id=self.adapter._orialis.device_id,user_name=self.adapter._orialis.device_id,message_id=request_id)
        return MessageEvent(text=text, source=source, user_id=source.user_id,user_name=source.user_name,
            message_id=request_id,timestamp=timestamp or datetime.fromtimestamp(0,timezone.utc),raw_message={})

    async def commit(self, event, response=None):
        self.adapter._canonicalize(event.source)
        with native_callback(self.runner,event,Path(self.home.name)):
            payload=await prepare_native(self.runner,event)
        source=event.source
        principal='messaging:'+json.dumps([source.profile,source.platform.value,source.chat_id,source.thread_id,source.user_id],separators=(',',':'))
        row=admit_session_input(self.db,epoch=self.epoch,principal_id=principal,session_id='owned',request_id=event.message_id,payload=payload)
        if response is not None:
            claimed=claim_session_input(self.db,epoch=self.epoch,session_id='owned')
            row=settle_session_input(self.db,epoch=self.epoch,admission_id=claimed['admission_id'],generation=claimed['generation'],
                outcome='completed',result={'result':{'final_response':response,'messages':[]},'usage':{}})
        return row

    async def test_epoch_zero_remains_exact_under_native_admission_after_adapter_restart(self):
        first=self.event()
        row=await self.commit(first)
        restarted=self.event()
        receipt=await self.adapter._native_retry_receipt(restarted)
        self.assertEqual(restarted.timestamp.timestamp(),0)
        with native_callback(self.runner,restarted,Path(self.home.name)):
            payload=await prepare_native(self.runner,restarted)
        retried=admit_session_input(self.db,epoch=self.epoch,principal_id=row['principal_id'],session_id='owned',request_id='stable',payload=payload)
        self.assertEqual(retried['admission_id'],row['admission_id'])

    async def test_owned_legacy_time_rehydrates_and_terminal_result_replays_without_execution(self):
        original=self.event(timestamp=datetime(2026,10,20,7,1,2))
        row=await self.commit(original,'Actual previously committed response')
        replay=self.event()
        receipt=await self.adapter._native_retry_receipt(replay)
        self.assertEqual(replay.timestamp, original.timestamp)
        with patch.object(self.adapter,'handle_message',side_effect=AssertionError('must not rerun inference')):
            await self.adapter._replay_native_terminal(replay,*receipt)
        reply=next(f for f in self.frames if f['type']=='message.reply')
        self.assertEqual(reply['content'],'Actual previously committed response')
        self.assertEqual(reply['reply_to'],'stable')
        stored=find_session_admission(self.db,principal_id=row['principal_id'],session_id='owned',request_id='stable')
        self.assertEqual(stored['payload'],row['payload'])

    async def test_actual_dispatch_of_legacy_terminal_after_restart_delivers_cached_reply(self):
        await self.commit(self.event(timestamp=datetime(2026,10,20,8,30)), 'Legacy cached response')
        old=self.adapter
        fresh=OrialisAdapter(SimpleNamespace(extra={'device_id':'JXCZ_TEST_Hermes'}))
        fresh._ws=object()
        fresh._running=True
        fresh._send_wire=old._send_wire
        fresh.gateway_runner=self.runner
        self.adapter=fresh
        self.runner.adapters[fresh.platform]=fresh
        with patch.object(fresh,'handle_message',side_effect=AssertionError('terminal retry must not execute')):
            await fresh._dispatch_message({'version':1,'type':'message.send','message_id':'stable',
                'conversation_id':'chat','content':'original'})
        replies=[f for f in self.frames if f['type']=='message.reply']
        self.assertEqual(len(replies),1)
        self.assertEqual(replies[0]['content'],'Legacy cached response')
        self.assertEqual(replies[0]['reply_to'],'stable')

    async def test_changed_payload_and_different_owner_or_session_cannot_replay(self):
        await self.commit(self.event(),'private cached reply')
        changed=self.event(text='changed payload')
        receipt=await self.adapter._native_retry_receipt(changed)
        with self.assertRaisesRegex(RuntimeStoreError,'admission_conflict'):
            await self.adapter._replay_native_terminal(changed,*receipt)
        foreign=self.event()
        foreign.source.user_id='different-user'
        self.assertIsNone(await self.adapter._native_retry_receipt(foreign))
        self.assertIsNone(await self.adapter._native_retry_receipt(self.event(conversation='other-chat')))
        self.assertFalse(any(f['type']=='message.reply' for f in self.frames))

    async def test_cached_native_media_response_uses_real_media_dispatch(self):
        marker=Path(self.home.name)/'cached-marker.txt'
        marker.write_text('cached existing bytes')
        await self.commit(self.event(),f'MEDIA:{marker.as_posix()}')
        replay=self.event()
        receipt=await self.adapter._native_retry_receipt(replay)
        uploaded=[]
        def upload(path,*args):
            uploaded.append(Path(path).read_bytes())
            return {'id':'cached-file','name':marker.name,'mime_type':'text/plain','size':marker.stat().st_size,
                'download_url':'https://orialis.test/api/v1/attachments/cached-file/download'}
        with patch.object(adapter_module,'_upload_attachment',upload):
            await self.adapter._replay_native_terminal(replay,*receipt)
        self.assertEqual(uploaded,[marker.read_bytes()])
        self.assertEqual(next(f for f in self.frames if f['type']=='message.reply')['attachments'][0]['id'],'cached-file')
