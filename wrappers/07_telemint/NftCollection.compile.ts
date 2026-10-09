import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    // lang: 'func',
    // targets: ['nft-collection-no-dns.fc']
    lang: 'tolk',
    entrypoint: 'telemint-collection-contract.tolk',
    withSrcLineComments: true,
    withStackComments: true,
}
