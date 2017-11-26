#import "iTermTextRenderer.h"

extern "C" {
#import "DebugLogging.h"
}

#import "iTermMetalCellRenderer.h"
#import "iTermSubpixelModelBuilder.h"
#import "iTermTextureArray.h"
#import "iTermTextureMap.h"
#import "iTermTextureMap+CPP.h"
#import "NSArray+iTerm.h"
#import "NSDictionary+iTerm.h"
#import <unordered_map>
#include <vector>

typedef struct {
    iTermTextPIU *piu;
    int x;
    int y;
} iTermTextFixup;

@interface iTermTextRendererTransientState ()

@property (nonatomic, strong) iTermTextureMap *textureMap;
@property (nonatomic, readonly) NSData *colorModels;
@property (nonatomic, readonly) NSData *piuData;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, readonly) NSArray<iTermTextureMapStage *> *allStages;
@end

// text color component, background color component
typedef std::pair<unsigned char, unsigned char> iTermColorComponentPair;

@implementation iTermTextRendererTransientState {
    iTermTextureMapStage *_stage;
    NSMutableArray<iTermFallbackTextureMap *> *_fallbackTextureMaps;

    id<MTLCommandBuffer> _commandBuffer;

    // Data's bytes contains a C array of vector_float4 with background colors.
    NSMutableArray<NSData *> *_backgroundColorDataArray;

    // PIUs that need their background colors set. They belong to parts of glyphs that spilled out
    // of their bounds.
    std::vector<iTermTextFixup> *_fixups;

    // Color models for this frame. Only used when there's no intermediate texture.
    NSMutableData *_colorModels;

    // Key is text, background color component. Value is color model number (0 is 1st, 1 is 2nd, etc)
    // and you can multiply the color model number by 256 to get its starting point in _colorModels.
    // Only used when there's no intermediate texture.
    std::map<iTermColorComponentPair, int> *_colorModelIndexes;
}

- (instancetype)initWithConfiguration:(__kindof iTermRenderConfiguration *)configuration {
    self = [super initWithConfiguration:configuration];
    if (self) {
        _backgroundColorDataArray = [NSMutableArray array];
        _fixups = new std::vector<iTermTextFixup>();
        _fallbackTextureMaps = [NSMutableArray array];

        iTermCellRenderConfiguration *cellConfiguration = configuration;
        if (!cellConfiguration.usingIntermediatePass) {
            _colorModels = [NSMutableData data];
            _colorModelIndexes = new std::map<iTermColorComponentPair, int>();
        }
    }
    return self;
}

- (void)dealloc {
    delete _fixups;
    if (_colorModelIndexes) {
        delete _colorModelIndexes;
    }
}

- (NSArray<iTermTextureMapStage *> *)allStages {
    NSArray<iTermTextureMapStage *> *fallbackStages = [_fallbackTextureMaps mapWithBlock:^id(iTermFallbackTextureMap *anObject) {
        return anObject.onlyStage;
    }];
    return [@[ _stage ] arrayByAddingObjectsFromArray:fallbackStages];
}

- (id<MTLBuffer>)newPIUBufferForStage:(iTermTextureMapStage *)stage {
    if (stage.piuData.length == 0) {
        return nil;
    }
    id<MTLBuffer> buffer = [_device newBufferWithBytes:stage.piuData.bytes
                                                length:sizeof(iTermTextPIU) * stage.numberOfInstances
                                               options:MTLResourceStorageModeShared];
    buffer.label = @"Text PIUs";
    return buffer;
}

- (void)willDrawWithDefaultBackgroundColor:(vector_float4)defaultBackgroundColor {
    DLog(@"WILL DRAW %@", self);
    // Fix up the background color of parts of glyphs that are drawn outside their cell.
    const int numRows = _backgroundColorDataArray.count;
    const int width = [_backgroundColorDataArray.firstObject length] / sizeof(iTermBackgroundColorPIU);
    for (auto &fixup : *_fixups) {
        if (fixup.y >= 0 && fixup.y < numRows && fixup.x >= 0 && fixup.x < width) {
            NSData *data = _backgroundColorDataArray[fixup.y];
            const vector_float4 *backgroundColors = (vector_float4 *)data.bytes;
            fixup.piu->backgroundColor = backgroundColors[fixup.x];
            if (_colorModels) {
                fixup.piu->colorModelIndex = [self colorModelIndexForPIU:fixup.piu];
            }
        } else {
            // Offscreen
            fixup.piu->backgroundColor = defaultBackgroundColor;
        }
    }
    [_stage blitNewTexturesFromStagingAreaWithCommandBuffer:_commandBuffer];
    DLog(@"END WILL DRAW");
}

- (void)prepareForDrawWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                             completion:(void (^)(void))completion {
    DLog(@"PREPARE FOR DRAW %@", self);
    _commandBuffer = commandBuffer;
    [_textureMap requestStage:^(iTermTextureMapStage *stage) {
        _stage = stage;
        completion();
    }];
    DLog(@"END PREPARE FOR DRAW");
}

- (NSUInteger)sizeOfNewPIUBuffer {
    // Reserve enough space for each cell to take 9 spots (cell plus all 8 neighbors)
    return sizeof(iTermTextPIU) * self.cellConfiguration.gridSize.width * self.cellConfiguration.gridSize.height * 9;
}

- (iTermTextPIU *)piuDataBytesInStage:(iTermTextureMapStage *)stage {
    if (!stage.piuData.length) {
        stage.piuData.length = self.sizeOfNewPIUBuffer;
    }
    return (iTermTextPIU *)stage.piuData.mutableBytes;
}

- (void)setGlyphKeysData:(NSData *)glyphKeysData
                   count:(int)count
          attributesData:(NSData *)attributesData
                     row:(int)row
     backgroundColorData:(nonnull NSData *)backgroundColorData
                creation:(NSDictionary<NSNumber *, NSImage *> *(NS_NOESCAPE ^)(int x, BOOL *emoji))creation {
    DLog(@"BEGIN setGlyphKeysData for %@", self);
    assert(row == _backgroundColorDataArray.count);
    [_backgroundColorDataArray addObject:backgroundColorData];
    const int width = self.cellConfiguration.gridSize.width;
    assert(count <= width);
    const iTermMetalGlyphKey *glyphKeys = (iTermMetalGlyphKey *)glyphKeysData.bytes;
    const iTermMetalGlyphAttributes *attributes = (iTermMetalGlyphAttributes *)attributesData.bytes;
    const float w = 1.0 / _textureMap.array.atlasSize.width;
    const float h = 1.0 / _textureMap.array.atlasSize.height;
    iTermTextureArray *array = _textureMap.array;
    const float cellHeight = self.cellConfiguration.cellSize.height;
    const float cellWidth = self.cellConfiguration.cellSize.width;
    const float yOffset = (self.cellConfiguration.gridSize.height - row - 1) * cellHeight;

    NSInteger lastIndex = 0;
    std::map<int, int> lastRelations;
    BOOL lastEmoji = NO;
    iTermTextureMapStage *stage;
    for (int x = 0; x < count; x++) {
        if (!glyphKeys[x].drawable) {
            continue;
        }
        std::map<int, int> relations;
        NSInteger index;
        NSInteger fallbackTextureMapIndex = -1;
        BOOL retained;
        BOOL emoji;
        if (x > 0 && !memcmp(&glyphKeys[x], &glyphKeys[x-1], sizeof(*glyphKeys))) {
            index = lastIndex;
            relations = lastRelations;
            emoji = lastEmoji;
            // When the glyphKey is repeated there's no need to acquire another lock.
            // If we get here, both this and the preceding glyphKey are drawable.
            retained = NO;
        } else {
            stage = _stage;
            index = [_stage findOrAllocateIndexOfLockedTextureWithKey:&glyphKeys[x]
                                                               column:x
                                                            relations:&relations
                                                                emoji:&emoji
                                                             creation:creation];
            if (index == iTermTextureMapStatusOutOfMemory) {
                for (iTermFallbackTextureMap *fallbackMap in _fallbackTextureMaps) {
                    ++fallbackTextureMapIndex;
                    stage = fallbackMap.onlyStage;
                    DLog(@"<fallback>");
                    index = [stage findOrAllocateIndexOfLockedTextureWithKey:&glyphKeys[x]
                                                                      column:x
                                                                   relations:&relations
                                                                       emoji:&emoji
                                                                    creation:creation];
                    DLog(@"</fallback>");
                    if (index != iTermTextureMapStatusOutOfMemory) {
                        break;
                    }
                }
                if (index == iTermTextureMapStatusOutOfMemory) {
                    // It's important to use the same capacity for the fallback texture map as the
                    // main texture map because that's how PIU texture coordinates are computed.
                    iTermFallbackTextureMap *newFallbackMap = [[iTermFallbackTextureMap alloc] initWithDevice:_device
                                                                                                     cellSize:self.cellConfiguration.cellSize
                                                                                                     capacity:_textureMap.capacity
                                                                                               numberOfStages:1];
                    [_fallbackTextureMaps addObject:newFallbackMap];
                    stage = newFallbackMap.onlyStage;
                    DLog(@"<fallback>");
                    index = [stage findOrAllocateIndexOfLockedTextureWithKey:&glyphKeys[x]
                                                                      column:x
                                                                   relations:&relations
                                                                       emoji:&emoji
                                                                    creation:creation];
                    DLog(@"</fallback>");
                }
            }
            retained = YES;
        }
        if (relations.size() > 1) {
            for (auto &kvp : relations) {
                const int part = kvp.first;
                const int index = kvp.second;
                iTermTextPIU *piu = [self piuDataBytesInStage:stage] + stage.numberOfInstances;
                const int dx = ImagePartDX(part);
                const int dy = ImagePartDY(part);
                piu->offset = simd_make_float2((x + dx) * cellWidth,
                                                -dy * cellHeight + yOffset);
                MTLOrigin origin = [array offsetForIndex:index];
                piu->textureOffset = (vector_float2){ origin.x * w, origin.y * h };
                piu->textColor = attributes[x].foregroundColor;
                piu->remapColors = !emoji;
                if (part == iTermTextureMapMiddleCharacterPart) {
                    piu->backgroundColor = attributes[x].backgroundColor;
                    if (_colorModels) {
                        piu->colorModelIndex = [self colorModelIndexForPIU:piu];
                    }
                } else {
                    iTermTextFixup fixup = {
                        .piu = piu,
                        .x = x + dx,
                        .y = row + dy
                    };
                    _fixups->push_back(fixup);
                }
                [self addIndex:index stage:stage retained:retained];
            }
        } else if (index >= 0) {
            iTermTextPIU *piu = [self piuDataBytesInStage:stage] + stage.numberOfInstances;
            piu->offset = simd_make_float2(x * self.cellConfiguration.cellSize.width,
                                            yOffset);
            MTLOrigin origin = [array offsetForIndex:index];
            piu->textureOffset = (vector_float2){ origin.x * w, origin.y * h };
            piu->textColor = attributes[x].foregroundColor;
            piu->backgroundColor = attributes[x].backgroundColor;
            piu->remapColors = !emoji;
            if (_colorModels) {
                piu->colorModelIndex = [self colorModelIndexForPIU:piu];
            }
            [self addIndex:index stage:stage retained:retained];
        }
        lastIndex = index;
        lastRelations = relations;
        lastEmoji = emoji;
    }
    DLog(@"END setGlyphKeysData for %@", self);
}

- (vector_int3)colorModelIndexForPIU:(iTermTextPIU *)piu {
    iTermColorComponentPair redPair = std::make_pair(piu->textColor.x * 255,
                                                     piu->backgroundColor.x * 255);
    iTermColorComponentPair greenPair = std::make_pair(piu->textColor.y * 255,
                                                       piu->backgroundColor.y * 255);
    iTermColorComponentPair bluePair = std::make_pair(piu->textColor.z * 255,
                                                      piu->backgroundColor.z * 255);
    vector_int3 result;
    auto it = _colorModelIndexes->find(redPair);
    if (it == _colorModelIndexes->end()) {
        result.x = [self allocateColorModelForColorPair:redPair];
    } else {
        result.x = it->second;
    }
    it = _colorModelIndexes->find(greenPair);
    if (it == _colorModelIndexes->end()) {
        result.y = [self allocateColorModelForColorPair:greenPair];
    } else {
        result.y = it->second;
    }
    it = _colorModelIndexes->find(bluePair);
    if (it == _colorModelIndexes->end()) {
        result.z = [self allocateColorModelForColorPair:bluePair];
    } else {
        result.z = it->second;
    }
    return result;
}

- (int)allocateColorModelForColorPair:(iTermColorComponentPair)colorPair {
    int i = _colorModelIndexes->size();
    iTermSubpixelModel *model = [[iTermSubpixelModelBuilder sharedInstance] modelForForegoundColor:colorPair.first / 255.0
                                                                                   backgroundColor:colorPair.second / 255.0];
    [_colorModels appendData:model.table];
    (*_colorModelIndexes)[colorPair] = i;
    return i;
}

- (void)didComplete {
    assert(_stage);
    DLog(@"BEGIN didComplete for %@", self);
    [_textureMap returnStage:_stage];
    [_fallbackTextureMaps enumerateObjectsUsingBlock:^(iTermFallbackTextureMap * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [obj returnStage:obj.onlyStage];
    }];
    _stage = nil;
    _fallbackTextureMaps = nil;
    DLog(@"END didComplete");
}

- (nonnull NSMutableData *)modelData  {
    if (_modelData == nil) {
        _modelData = [[NSMutableData alloc] initWithLength:sizeof(iTermTextPIU) * self.cellConfiguration.gridSize.width * self.cellConfiguration.gridSize.height];
    }
    return _modelData;
}

- (void)addIndex:(NSInteger)index stage:(iTermTextureMapStage *)stage retained:(BOOL)retained {
    if (retained) {
        DLog(@"Record index %@ locked for %@", @(index), self);
        stage.locks->push_back(index);
    } else {
        DLog(@"Not retaining reference to index %@ for %@", @(index), self);
    }
    [stage incrementInstances];
}

@end

@implementation iTermTextRenderer {
    iTermMetalCellRenderer *_cellRenderer;
    iTermTextureMap *_textureMap;
    id<MTLBuffer> _models;
}

- (id<MTLBuffer>)subpixelModelsForState:(iTermTextRendererTransientState *)tState {
    if (tState.colorModels) {
        if (tState.colorModels.length == 0) {
            // Blank screen, emoji-only screen, etc. The buffer won't get accessed but it can't be nil.
            return [_cellRenderer.device newBufferWithBytes:""
                                                     length:1
                                                    options:MTLResourceStorageModeShared];
        }
        return [_cellRenderer.device newBufferWithBytes:tState.colorModels.bytes
                                                 length:tState.colorModels.length
                                                options:MTLResourceStorageModeShared];
    }

    if (_models == nil) {
        NSMutableData *data = [NSMutableData data];
        // The fragment function assumes we use the value 17 here. It's
        // convenient that 17 evenly divides 255 (17 * 15 = 255).
        float stride = 255.0/17.0;
        for (float textColor = 0; textColor < 256; textColor += stride) {
            for (float backgroundColor = 0; backgroundColor < 256; backgroundColor += stride) {
                iTermSubpixelModel *model = [[iTermSubpixelModelBuilder sharedInstance] modelForForegoundColor:MIN(MAX(0, textColor / 255.0), 1)
                                                                                               backgroundColor:MIN(MAX(0, backgroundColor / 255.0), 1)];
                [data appendData:model.table];
            }
        }
#warning TODO: Only create one per device
        _models = [_cellRenderer.device newBufferWithBytes:data.bytes
                                                    length:data.length
                                                   options:MTLResourceStorageModeShared];
    }
    return _models;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        _cellRenderer = [[iTermMetalCellRenderer alloc] initWithDevice:device
                                                    vertexFunctionName:@"iTermTextVertexShader"
                                                  fragmentFunctionName:@"iTermTextFragmentShader"
                                                              blending:YES
                                                        piuElementSize:sizeof(iTermTextPIU)
                                                   transientStateClass:[iTermTextRendererTransientState class]];
    }
    return self;
}

- (BOOL)canRenderImmediately {
    return _textureMap.haveStageAvailable;
}

- (void)createTransientStateForCellConfiguration:(iTermCellRenderConfiguration *)configuration
                                   commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                      completion:(void (^)(__kindof iTermMetalRendererTransientState * _Nonnull))completion {
    // NOTE: Any time a glyph overflows its bounds into a neighboring cell it's possible the strokes will intersect.
    // I haven't thought of a way to make that look good yet without having to do one draw pass per overflow glyph that
    // blends using the output of the preceding passes.
    _cellRenderer.fragmentFunctionName = configuration.usingIntermediatePass ? @"iTermTextFragmentShaderWithBlending" : @"iTermTextFragmentShaderSolidBackground";
    [_cellRenderer createTransientStateForCellConfiguration:configuration
                                              commandBuffer:commandBuffer
                                                 completion:^(__kindof iTermMetalCellRendererTransientState * _Nonnull transientState) {
                                                     [self initializeTransientState:transientState
                                                                      commandBuffer:commandBuffer
                                                                         completion:completion];
                                                 }];
}

- (void)initializeTransientState:(iTermTextRendererTransientState *)tState
                   commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                      completion:(void (^)(__kindof iTermMetalCellRendererTransientState * _Nonnull))completion {
    // This capacity gives the size of the glyph cache. If there are more glyphs than fit here we'll
    // create temporary fallback textures which have no caching and are *very* slow. This is limited
    // by Metal's 16384x16384 texture size limit. If a glyph is larger than one cell (e.g., emoji)
    // then it will use more than one entry in the texture map. It's possible for a single frame
    // to need more than first in the texture map. In that case we create temporary texture maps
    // as needed. There is no caching in these and it is terribly slow.
    const NSInteger capacity = tState.cellConfiguration.gridSize.width * tState.cellConfiguration.gridSize.height * 2;
    if (_textureMap == nil ||
        !CGSizeEqualToSize(_textureMap.cellSize, tState.cellConfiguration.cellSize) ||
        _textureMap.capacity != capacity) {
        _textureMap = [[iTermTextureMap alloc] initWithDevice:_cellRenderer.device
                                                     cellSize:tState.cellConfiguration.cellSize
                                                     capacity:capacity
                                               numberOfStages:2];
        _textureMap.label = [NSString stringWithFormat:@"[texture map for %p]", self];
        _textureMap.array.texture.label = @"Texture grid for session";
    }
    tState.textureMap = _textureMap;
    tState.device = _cellRenderer.device;

    // The vertex buffer's texture coordinates depend on the texture map's atlas size so it must
    // be initialized after the texture map.
    tState.vertexBuffer = [self newQuadOfSize:tState.cellConfiguration.cellSize];

    [tState prepareForDrawWithCommandBuffer:commandBuffer completion:^{
        completion(tState);
    }];
}

- (id<MTLBuffer>)newQuadOfSize:(CGSize)size {
    const float vw = static_cast<float>(size.width);
    const float vh = static_cast<float>(size.height);

    const float w = size.width / _textureMap.array.atlasSize.width;
    const float h = size.height / _textureMap.array.atlasSize.height;

    const iTermVertex vertices[] = {
        // Pixel Positions, Texture Coordinates
        { { vw,  0 }, { w, 0 } },
        { { 0,   0 }, { 0, 0 } },
        { { 0,  vh }, { 0, h } },

        { { vw,  0 }, { w, 0 } },
        { { 0,  vh }, { 0, h } },
        { { vw, vh }, { w, h } },
    };
    return [_cellRenderer.device newBufferWithBytes:vertices
                                             length:sizeof(vertices)
                                            options:MTLResourceStorageModeShared];
}

- (NSDictionary *)texturesForTransientState:(iTermTextRendererTransientState *)tState
                                      stage:(iTermTextureMapStage * _Nonnull)stage {
    id<MTLTexture> texture;
    if ([stage isKindOfClass:[iTermFallbackTextureMapStage class]]) {
        texture = stage.textureMap.array.texture;
        assert(texture);
    } else {
        texture = tState.textureMap.array.texture;
        assert(texture);
    }
    NSDictionary *textures = @{ @(iTermTextureIndexPrimary): texture };
    if (tState.cellConfiguration.usingIntermediatePass) {
        textures = [textures dictionaryBySettingObject:tState.backgroundTexture forKey:@(iTermTextureIndexBackground)];
    }
    return textures;
}

- (void)drawWithRenderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder
               transientState:(__kindof iTermMetalCellRendererTransientState *)transientState {
    iTermTextRendererTransientState *tState = transientState;
    tState.vertexBuffer.label = @"Text vertex buffer";
    tState.offsetBuffer.label = @"Offset";

    [tState.allStages enumerateObjectsUsingBlock:^(iTermTextureMapStage * _Nonnull stage, NSUInteger idx, BOOL * _Nonnull stop) {
        if (stage.numberOfInstances) {
            id<MTLBuffer> piuBuffer = [tState newPIUBufferForStage:stage];
            assert(piuBuffer);
//            if (idx > 0) {
//                tState.pipelineState = [_cellRenderer newPipelineState];
//            }
            [_cellRenderer drawWithTransientState:tState
                                    renderEncoder:renderEncoder
                                 numberOfVertices:6
                                     numberOfPIUs:stage.numberOfInstances
                                    vertexBuffers:@{ @(iTermVertexInputIndexVertices): tState.vertexBuffer,
                                                     @(iTermVertexInputIndexPerInstanceUniforms): piuBuffer,
                                                     @(iTermVertexInputIndexOffset): tState.offsetBuffer }
                                  fragmentBuffers:@{ @(iTermFragmentBufferIndexColorModels): [self subpixelModelsForState:tState] }
                                         textures:[self texturesForTransientState:tState stage:stage]];
        }
    }];
}

@end