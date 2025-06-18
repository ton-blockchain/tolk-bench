import { CompilerConfig } from '@ton/blueprint';

export const compile: CompilerConfig = {
    // lang: 'func',
    // targets: ['nft-item.fc']
    lang: 'tolk',
    entrypoint: 'nft-item.tolk',
    withSrcLineComments: true,
    withStackComments: true,
};
