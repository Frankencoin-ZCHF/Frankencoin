#!/usr/bin/env python3
"""Read-only FCS deployment verification. Python standard library only; no wallet.
Usage: python3 verify_fcs_deployment.py --rpc URL --block 26038677
Sourcify validates compiler/source matching; this script independently checks that
its onchain runtime is the code returned by the selected Ethereum node.
"""
import argparse
import hashlib
import json
import urllib.request

FCS = '0xdb861830d9ae2d1fcf99fa0cfd3973de382b0b5b'
ZCHF = '0xb58e61c3098d85632df34eecfb899a1ed80921cb'
FPS = '0x1ba26788dfde592fec8bcb0eaff472a42be341b2'
SELECTORS = {'asset': '0x38d52e0f', 'FPS1': '0x063835e5', 'isBinding': '0x9e4b5745', 'canRedeem': '0x151535b9'}

def fetch(url, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json', 'User-Agent': 'FCS-hook-verifier/1'})
    with urllib.request.urlopen(req, timeout=60) as response:
        return json.load(response)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rpc', default='https://eth-mainnet.public.blastapi.io')
    parser.add_argument('--block', type=int, default=26038677)
    args = parser.parse_args()
    def rpc(method, params):
        response = fetch(args.rpc, {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params})
        if 'error' in response:
            raise RuntimeError(response['error'])
        return response['result']
    block = hex(args.block)
    if int(rpc('eth_chainId', []), 16) != 1:
        raise RuntimeError('Expected Ethereum mainnet chain ID 1')
    verified = fetch(f'https://sourcify.dev/server/v2/contract/1/{FCS}?fields=all')
    if verified.get('runtimeMatch') != 'exact_match' or verified.get('creationMatch') != 'exact_match':
        raise RuntimeError('Expected exact runtime and creation source matches')
    code = rpc('eth_getCode', [FCS, block])
    if code == '0x' or code.lower() != verified['runtimeBytecode']['onchainBytecode'].lower():
        raise RuntimeError('RPC code does not match Sourcify deployment runtime')
    def call(address, data):
        return rpc('eth_call', [{'to': address, 'data': data}, block])
    asset = '0x' + call(FCS, SELECTORS['asset'])[-40:]
    fps = '0x' + call(FCS, SELECTORS['FPS1'])[-40:]
    if asset.lower() != ZCHF or fps.lower() != FPS:
        raise RuntimeError('Unexpected FCS underlying/reserve')
    binding = bool(int(call(FCS, SELECTORS['isBinding']), 16))
    eligible = bool(int(call(fps, SELECTORS['canRedeem'] + FCS[2:].zfill(64)), 16))
    header = rpc('eth_getBlockByNumber', [block, False])
    print(json.dumps({'address': FCS, 'chainId': 1, 'block': args.block,
        'blockHash': header['hash'], 'codeMatchesVerifiedRuntime': True,
        'asset': asset, 'FPS1': fps, 'isBinding': binding,
        'underlyingRedeemEligible': eligible, 'redemptionsEnabled': binding and eligible,
        'sourceSha256': {n: hashlib.sha256(s['content'].encode()).hexdigest()
                         for n, s in verified['sources'].items()}}, indent=2))

if __name__ == '__main__':
    main()
