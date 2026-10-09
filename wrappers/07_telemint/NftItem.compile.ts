import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    // lang: 'func',
    // targets: ['nft-item-no-dns-cheap.fc']
    lang: 'tolk',
    entrypoint: 'telemint-item-contract.tolk',
    withSrcLineComments: true,
    withStackComments: true,
}
