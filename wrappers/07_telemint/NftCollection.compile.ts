import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    // lang: 'func',
    // targets: ['nft-collection-no-dns.fc']
    lang: 'tolk',
    entrypoint: 'nft-collection-no-dns.tolk',
    withSrcLineComments: true,
    withStackComments: true,
}
