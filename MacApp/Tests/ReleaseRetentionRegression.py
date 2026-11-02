"""Retention tests use synthetic public metadata; no credentials or live DELETE."""
import base64
import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import release_retention as retention
import publish_github as pub

KEY = '11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo='
TEAM = 'FWCSVFT76D'


class FakeGitHub:
    def __init__(self):
        self.rows = {}
        self.asset_rows = {}
        self.files = {}
        self.public = {}
        self.operations = []
        self.lock = None
        self.counter = 0
        self.ambiguous_delete = False
        self.fail_delete = None
        self.before_delete = None
        self.immutable = True
        self.public_repo = True

    def api(self, endpoint, method='GET', payload=None, missing=False):
        self.operations.append((method, endpoint))
        if endpoint == pub.API:
            return {'full_name':pub.REPOSITORY,'private':not self.public_repo,'archived':False,'default_branch':'main'}
        if endpoint == pub.API + '/immutable-releases':
            return {'enabled':self.immutable}
        if endpoint == pub.API + '/git/ref/heads/main':
            return {'object':{'sha':'a'*40}}
        if endpoint.startswith(pub.API + '/git/commits/'):
            return {'tree':{'sha':'b'*40}}
        if endpoint == pub.API + '/git/commits' and method == 'POST':
            self.counter += 1
            return {'sha':format(self.counter,'040x')}
        if endpoint == pub.API + '/git/ref/' + retention.LOCK:
            return {'object':{'sha':self.lock}} if self.lock else None
        if endpoint == pub.API + '/git/refs' and method == 'POST':
            if self.lock:
                raise pub.GitHubError('POST',422)
            self.lock = payload['sha']
            return {'object':{'sha':self.lock}}
        if endpoint == pub.API + '/git/refs/' + retention.LOCK and method == 'DELETE':
            self.lock = None
            return None
        if '/contents/' in endpoint:
            path = endpoint.split('/contents/')[1].split('?')[0]
            if method == 'PUT':
                assert path not in self.files
                self.files[path] = base64.b64decode(payload['content'])
            value = self.files.get(path)
            return None if value is None else {'type':'file','encoding':'base64','size':len(value),'content':base64.b64encode(value).decode()}
        if endpoint.startswith(pub.API + '/releases?'):
            page = int(endpoint.rsplit('=',1)[1])
            return copy.deepcopy(list(self.rows.values())[(page-1)*100:page*100])
        if endpoint.startswith(pub.API + '/releases/tags/'):
            tag = endpoint.rsplit('/',1)[1]
            return next((copy.deepcopy(r) for r in self.rows.values() if r['tag_name'] == tag),None)
        if endpoint.startswith(pub.API + '/releases/'):
            identifier = int(endpoint.rsplit('/',1)[1])
            if method == 'DELETE':
                if self.before_delete:
                    self.before_delete(identifier)
                if identifier == self.fail_delete:
                    raise pub.GitHubError('DELETE',503)
                self.rows.pop(identifier, None)
                if self.ambiguous_delete:
                    self.ambiguous_delete = False
                    raise pub.GitHubError('DELETE')
                return None
            return copy.deepcopy(self.rows.get(identifier))
        raise AssertionError((endpoint,method))

    def assets(self, identifier):
        return copy.deepcopy(self.asset_rows[identifier])

    def fetch(self, url, limit, missing=False, website=False):
        data = self.public.get(url)
        if data is None and not missing:
            raise ValueError('Public metadata unavailable')
        if data is not None and len(data) > limit:
            raise ValueError('Public metadata exceeds bound')
        return data


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {'ECHO_SPARKLE_PUBLIC_KEY':KEY,'ECHO_TEAM_ID':TEAM})
        self.env.start(); self.addCleanup(self.env.stop)
        self.verification = patch.object(retention.release,'verify_feed',side_effect=lambda path,key,tool:ET.parse(path).getroot())
        self.verify = self.verification.start(); self.addCleanup(self.verification.stop)
        self.github = FakeGitHub()
        self.settings = json.loads((Path(__file__).resolve().parents[1]/'scripts/release-retention-policy.json').read_text())
        for build in range(100,106):
            self.add_release(build,'stable')
        for build in range(108,111):
            self.add_release(build,'test')
        self.feed('stable',[105]); self.feed('test',[110])
        self.site([self.tag(105),self.tag(103)])

    def tag(self, build, channel='stable', version='2.0.0'):
        return f'{channel}-{version}-{build}'

    def add_release(self, build, channel, version='2.0.0', age=172800):
        tag = self.tag(build,channel,version)
        filename = f'Echo-{version}-{build}-universal' + ('' if channel == 'stable' else '-'+channel) + '.dmg'
        dmg = b'synthetic archive '+str(build).encode()
        meta = {'channel':channel,'version':version,'build':str(build),'filename':filename,'bundleIdentifier':'uz.voicelab.desktop',
                'publicEDKey':KEY,'teamID':TEAM,'architectures':['arm64','x86_64'],'bytes':len(dmg),'sha256':retention.sha(dmg),
                'sourceCommit':'c'*40,'sourceDirty':False}
        files = {filename:dmg,'release.json':json.dumps(meta).encode(),'release-notes.html':b'<p>Verified notes</p>',
                 'SHA256SUMS.txt':(retention.sha(dmg)+'  '+filename+'\n').encode()}
        self.github.rows[build] = {'id':build,'tag_name':tag,'draft':False,'immutable':True,'prerelease':channel!='stable',
            'name':f'Echo {version} ({build}) — {channel}',
            'published_at':datetime.fromtimestamp(time.time()-age,timezone.utc).isoformat(),
            'body':f'Echo for macOS.\n\nPrepared publication SHA256: `{"d"*64}`\n\nSigned feed SHA256: `{"e"*64}`\n'}
        self.github.asset_rows[build] = []
        for index,(name,data) in enumerate(files.items()):
            url = f'{pub.ASSET_BASE}/{tag}/{name}'
            self.github.asset_rows[build].append({'id':build*10+index,'name':name,'state':'uploaded','size':len(data),
                'digest':'sha256:'+retention.sha(data),'browser_download_url':url})
            self.github.public[url] = data

    def feed(self, channel, builds, extra=''):
        tree = ET.Element('rss'); node=ET.SubElement(tree,'channel')
        ET.SubElement(node,'link').text=f'{pub.FEED_BASE}/{channel}/appcast.xml'
        for build in builds:
            row=self.github.rows[build]; asset=self.github.asset_rows[build][0]
            item=ET.SubElement(node,'item')
            ET.SubElement(item,'enclosure',{'url':asset['browser_download_url']})
        if extra:
            node.append(ET.fromstring(extra))
        data=ET.tostring(tree)
        self.github.files[f'{channel}/appcast.xml']=data
        self.github.public[f'{pub.FEED_BASE}/{channel}/appcast.xml']=data

    def site(self, tags, index=None):
        value=retention.canonical({'schema_version':1,'repository':pub.REPOSITORY,'protected_tags':tags})
        for url in self.settings['protection_urls'] if index is None else [self.settings['protection_urls'][index]]:
            self.github.public[url]=value

    def plan(self):
        return retention.make_plan(self.github,self.settings,KEY,'verifier',self.github.fetch)

    def apply(self, plan):
        with retention.OperationLock(self.github,'retention') as lock:
            return retention.apply_plan(self.github,plan,retention.sha(retention.canonical(plan)),'verifier',self.github.fetch,lock)

    def deletions(self):
        return [path for method,path in self.github.operations if method=='DELETE' and '/releases/' in path]

    def test_plan_is_read_only_and_keeps_channel_limits(self):
        p=self.plan()
        self.assertEqual([r['id'] for r in p['delete']],[100,101,102,108,109])
        self.assertTrue(all(method=='GET' for method,_ in self.github.operations))

    def test_build_order_wins_over_marketing_version(self):
        self.add_release(115,'stable','1.0.0')
        self.assertIn('stable-1.0.0-115',self.plan()['kept_tags'])
        self.assertNotIn(115,[r['id'] for r in self.plan()['delete']])

    def test_both_website_fallbacks_protected(self):
        self.site([self.tag(100)],index=0);self.site([self.tag(101)],index=1)
        self.assertEqual([r['id'] for r in self.plan()['delete']],[102,108,109])

    def test_old_feed_reference_beats_limit(self):
        self.feed('stable',[105,100])
        self.assertNotIn(100,[r['id'] for r in self.plan()['delete']])

    def test_delta_enclosure_reference_protected(self):
        url=self.github.asset_rows[100][0]['browser_download_url']
        self.feed('stable',[105],f'<deltas><enclosure url="{url}" /></deltas>')
        self.assertNotIn(100,[r['id'] for r in self.plan()['delete']])

    def test_missing_site_defers_all(self):
        del self.github.public[self.settings['protection_urls'][1]]
        with self.assertRaises(ValueError):self.plan()
        self.assertEqual(self.deletions(),[])

    def test_empty_site_protection_rejected(self):
        self.site([])
        with self.assertRaises(ValueError):self.plan()

    def test_pending_raw_cdn_blocks_cleanup(self):
        self.github.public[f'{pub.FEED_BASE}/stable/appcast.xml']=b'cached old feed'
        with self.assertRaisesRegex(ValueError,'CDN'):self.plan()

    def test_unverified_signature_blocks_cleanup(self):
        self.verify.side_effect=ValueError('Invalid signature')
        with self.assertRaises(ValueError):self.plan()

    def test_unknown_feed_host_fails_closed(self):
        self.feed('stable',[105],'<enclosure url="https://example.org/unknown.dmg"/>')
        with self.assertRaises(ValueError):self.plan()

    def test_no_stable_feed_defers_cleanup(self):
        self.github.files.pop('stable/appcast.xml');self.github.public.pop(f'{pub.FEED_BASE}/stable/appcast.xml')
        with self.assertRaisesRegex(ValueError,'stable feed'):self.plan()

    def test_drafts_mutable_unknown_assets_not_deleted(self):
        self.github.rows[100]['draft']=True
        self.github.rows[101]['immutable']=False
        self.github.asset_rows[102][0]['name']='unknown.dmg'
        self.assertEqual([r['id'] for r in self.plan()['delete']],[108,109])

    def test_metadata_digest_mismatch_preserves_release(self):
        asset=next(a for a in self.github.asset_rows[100] if a['name']=='release.json')
        self.github.public[asset['browser_download_url']]=b'changed'
        self.assertNotIn(100,[r['id'] for r in self.plan()['delete']])

    def test_grace_period_preserves_recent_build(self):
        self.add_release(100,'stable',age=60)
        self.assertNotIn(100,[r['id'] for r in self.plan()['delete']])

    def test_apply_archives_exact_metadata_before_whole_delete(self):
        p=self.plan();deleted=self.apply(p)
        self.assertEqual(deleted,[100,101,102,108,109])
        audit='retention/audits/'+retention.sha(retention.canonical(p))+'.json'
        self.assertEqual(json.loads(self.github.files[audit]),p)
        methods=self.github.operations
        archive=next(i for i,(m,u) in enumerate(methods) if m=='PUT' and '/retention/audits/' in u)
        first=next(i for i,(m,u) in enumerate(methods) if m=='DELETE' and '/releases/' in u)
        self.assertLess(archive,first)
        self.assertFalse(any('/assets/' in u or '/tags/' in u for m,u in methods if m=='DELETE'))

    def test_changed_site_after_plan_rejected(self):
        p=self.plan();self.site([self.tag(100)])
        with self.assertRaises(ValueError):self.apply(p)
        self.assertEqual(self.deletions(),[])

    def test_changed_feed_after_plan_rejected(self):
        p=self.plan();self.feed('stable',[105,100])
        with self.assertRaises(ValueError):self.apply(p)
        self.assertEqual(self.deletions(),[])

    def test_release_id_replacement_rejected(self):
        p=self.plan();self.github.rows[100]['tag_name']=self.tag(99)
        with self.assertRaises(ValueError):self.apply(p)
        self.assertEqual(self.deletions(),[])

    def test_partial_delete_resumes_same_plan_without_recreating_tag(self):
        p=self.plan();self.github.fail_delete=101
        with self.assertRaises(ValueError):self.apply(p)
        self.assertNotIn(100,self.github.rows);self.assertIn(101,self.github.rows)
        self.github.fail_delete=None
        self.assertEqual(self.apply(p),[100,101,102,108,109])

    def test_ambiguous_delete_reconciles_absence(self):
        p=self.plan();self.github.ambiguous_delete=True
        self.assertEqual(self.apply(p),[100,101,102,108,109])

    def test_protection_change_during_deletion_stops_remaining(self):
        p=self.plan()
        self.github.before_delete=lambda identifier:self.site([self.tag(101)])
        with self.assertRaises(ValueError):self.apply(p)
        self.assertNotIn(100,self.github.rows);self.assertIn(101,self.github.rows)

    def test_wrong_plan_hash_no_mutation(self):
        p=self.plan()
        with self.assertRaises(ValueError):retention.apply_plan(self.github,p,'0'*64,'verifier',self.github.fetch)
        self.assertEqual(self.deletions(),[])

    def test_expired_plan_cannot_delete(self):
        p=self.plan();p['created_at']-=86401
        with self.assertRaises(ValueError):self.apply(p)

    def test_audit_failure_precedes_every_delete(self):
        p=self.plan()
        original=self.github.api
        def reject(endpoint,method='GET',payload=None,missing=False):
            if method=='PUT':raise pub.GitHubError('PUT',503)
            return original(endpoint,method,payload,missing)
        with patch.object(self.github,'api',side_effect=reject):
            with self.assertRaises(ValueError):self.apply(p)
        self.assertEqual(self.deletions(),[])

    def test_pagination_bound_fail_closed(self):
        rows=[{'id':i,'tag_name':f'unknown-{i}'} for i in range(1,101)]
        def page(endpoint,*args,**kwargs):
            number=int(endpoint.rsplit('=',1)[1])
            return [{**r,'id':r['id']+number*100,'tag_name':r['tag_name']+'-'+str(number)} for r in rows]
        with patch.object(self.github,'api',side_effect=page):
            with self.assertRaisesRegex(ValueError,'pagination'):retention.listing(self.github)

    def test_repository_immutability_not_disabled(self):
        self.github.immutable=False
        with self.assertRaises(ValueError):self.plan()
        self.assertTrue(all(m=='GET' for m,_ in self.github.operations))

    def test_policy_cannot_reduce_minimum_or_drop_host(self):
        for field,value in [('keep',{'stable':2,'test':1,'beta':1}),('protection_urls',self.settings['protection_urls'][:1]),('minimum_age_hours',0)]:
            bad=copy.deepcopy(self.settings);bad[field]=value
            with self.assertRaises(ValueError):retention.validate_policy(bad)

    def test_lock_serializes_and_releases(self):
        with retention.OperationLock(self.github,'publish') as lock:
            lock.check()
            with self.assertRaises(ValueError):
                with retention.OperationLock(self.github,'retention'):pass
        self.assertIsNone(self.github.lock)

    def test_no_timeout_steal_and_exact_recovery(self):
        self.github.lock='f'*40
        with self.assertRaises(ValueError):
            with retention.OperationLock(self.github,'publish'):pass
        with self.assertRaises(ValueError):retention.unlock(self.github,'e'*40)
        self.assertEqual(self.github.lock,'f'*40)
        retention.unlock(self.github,'f'*40)
        self.assertIsNone(self.github.lock)

    def test_changed_lock_is_never_deleted_by_old_owner(self):
        with retention.OperationLock(self.github,'publish'):
            self.github.lock='f'*40
        self.assertEqual(self.github.lock,'f'*40)

    def test_cleanup_failure_does_not_fail_verified_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(retention,'policy',side_effect=RuntimeError('synthetic cleanup failure')):
                retention.after_publication(self.github,Path(directory)/'policy','verify',None,Path(directory)/'plan')


if __name__=='__main__':unittest.main()
