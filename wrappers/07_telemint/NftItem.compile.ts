import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    // lang: 'func',
    // targets: ['nft-item-no-dns-cheap.fc']
    lang: 'tolk',
    entrypoint: 'TelemintItem.tolk',
    withSrcLineComments: true,
    withStackComments: true,
}
