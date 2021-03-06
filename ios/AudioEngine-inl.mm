
#include "AudioEngine-inl.h"

#import <OpenAL/alc.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#import "AudioEngine.h"
#import "FileIOIOS.h"
//#import "CacheManager.h"

static ALCdevice *s_ALDevice = nullptr;
static ALCcontext *s_ALContext = nullptr;


class AudioEngineThreadPool
{
public:
    AudioEngineThreadPool()
    : _running(true)
    , _numThread(6)
    {
        _threads.reserve(_numThread);
        _tasks.reserve(_numThread);
        
        for (int index = 0; index < _numThread; ++index) {
            _tasks.push_back(nullptr);
            _threads.push_back( std::thread( std::bind(&AudioEngineThreadPool::threadFunc,this,index) ) );
        }
    }
    
    void addTask(const std::function<void()> &task){
        _taskMutex.lock();
        int targetIndex = -1;
        for (int index = 0; index < _numThread; ++index) {
            if (_tasks[index] == nullptr) {
                targetIndex = index;
                _tasks[index] = task;
                break;
            }
        }
        if (targetIndex == -1) {
            _tasks.push_back(task);
            _threads.push_back( std::thread( std::bind(&AudioEngineThreadPool::threadFunc,this,_numThread) ) );
            
            _numThread++;
        }
        _taskMutex.unlock();
        
        _sleepCondition.notify_all();
    }
    
    void destroy()
    {
        _running = false;
        _sleepCondition.notify_all();
        
        for (int index = 0; index < _numThread; ++index) {
            _threads[index].join();
        }
    }
    
private:
    bool _running;
    std::vector<std::thread>  _threads;
    std::vector< std::function<void ()> > _tasks;
    
    void threadFunc(int index)
    {
        while (_running) {
            std::function<void ()> task = nullptr;
            _taskMutex.lock();
            task = _tasks[index];
            _taskMutex.unlock();
            
            if (nullptr == task)
            {
                std::unique_lock<std::mutex> lk(_sleepMutex);
                _sleepCondition.wait(lk);
                continue;
            }
            
            task();
            
            _taskMutex.lock();
            _tasks[index] = nullptr;
            _taskMutex.unlock();
        }
    }
    
    int _numThread;
    
    std::mutex _taskMutex;
    std::mutex _sleepMutex;
    std::condition_variable _sleepCondition;
    
};

@interface AudioEngineSessionHandler : NSObject
{
}

-(id) init;
-(void)handleInterruption:(NSNotification*)notification;

@end

@implementation AudioEngineSessionHandler

void AudioEngineInterruptionListenerCallback(void* user_data, UInt32 interruption_state)
{
    if (kAudioSessionBeginInterruption == interruption_state)
    {
      alcMakeContextCurrent(nullptr);
    }
    else if (kAudioSessionEndInterruption == interruption_state)
    {
      OSStatus result = AudioSessionSetActive(true);
      if (result) NSLog(@"Error setting audio session active! %d\n", result);

      alcMakeContextCurrent(s_ALContext);
    }
}

-(id) init
{
    if (self == [super init])
    {
      if ([[[UIDevice currentDevice] systemVersion] intValue] > 5) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleInterruption:) name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
      }
      else {
        AudioSessionInitialize(NULL, NULL, AudioEngineInterruptionListenerCallback, self);
      }
    }
    return self;
}

-(void)handleInterruption:(NSNotification*)notification
{
    if ([notification.name isEqualToString:AVAudioSessionInterruptionNotification]) {
        NSInteger reason = [[[notification userInfo] objectForKey:AVAudioSessionInterruptionTypeKey] integerValue];
        if (reason == AVAudioSessionInterruptionTypeBegan) {
            alcMakeContextCurrent(NULL);
        }
        
        if (reason == AVAudioSessionInterruptionTypeEnded) {
            OSStatus result = AudioSessionSetActive(true);
            if (result) NSLog(@"Error setting audio session active! %d\n", result);
            
            alcMakeContextCurrent(s_ALContext);
        }
    }
}

-(void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionInterruptionNotification object:nil];
    
    [super dealloc];
}
@end

static id s_AudioEngineSessionHandler = nullptr;

AudioEngineImpl::AudioEngineImpl()
: _threadPool(nullptr)
, _currentAudioID(0)
{
    
}

AudioEngineImpl::~AudioEngineImpl()
{
    if (s_ALContext) {
        alDeleteSources(MAX_AUDIOINSTANCES, _alSources);
        
        _audioCaches.clear();
        
        alcMakeContextCurrent(nullptr);
        alcDestroyContext(s_ALContext);
    }
    if (s_ALDevice) {
        alcCloseDevice(s_ALDevice);
    }
    if (_threadPool) {
        _threadPool->destroy();
        delete _threadPool;
    }
    
    [s_AudioEngineSessionHandler release];
}

bool AudioEngineImpl::init()
{
    bool ret = false;
    do{
        s_AudioEngineSessionHandler = [[AudioEngineSessionHandler alloc] init];
        
        s_ALDevice = alcOpenDevice(nullptr);
        
        if (s_ALDevice) {
            auto alError = alGetError();
            s_ALContext = alcCreateContext(s_ALDevice, nullptr);
            alcMakeContextCurrent(s_ALContext);
            
            alGenSources(MAX_AUDIOINSTANCES, _alSources);
            alError = alGetError();
            if(alError != AL_NO_ERROR)
            {
                printf("%s:generating sources fail! error = %x\n", __PRETTY_FUNCTION__, alError);
                break;
            }
            
            for (int i = 0; i < MAX_AUDIOINSTANCES; ++i) {
                _alSourceUsed[_alSources[i]] = false;
            }
            
            _threadPool = new (std::nothrow) AudioEngineThreadPool();
            ret = true;
        }
    }while (false);
    
    return ret;
}

int AudioEngineImpl::play2d(std::string &filePath ,bool loop ,float volume)
{
    if (s_ALDevice == nullptr || filePath.empty()) {
        return AudioEngine::INVALID_AUDIO_ID;
    }
    
    bool sourceFlag = false;
    ALuint alSource = 0;
    for (int i = 0; i < MAX_AUDIOINSTANCES; ++i) {
        alSource = _alSources[i];
        
        if ( !_alSourceUsed[alSource]) {
            sourceFlag = true;
            break;
        }
    }
    if(!sourceFlag){
        return AudioEngine::INVALID_AUDIO_ID;
    }
    
    AudioCache* audioCache = nullptr;
    auto it = _audioCaches.find(filePath);
    if (it == _audioCaches.end()) {
        audioCache = &_audioCaches[filePath];
        audioCache->_fileFullPath = filePath;
        
        _threadPool->addTask(std::bind(&AudioCache::readDataTask, audioCache));
    }
    else {
        audioCache = &it->second;
    }
    
    auto player = &_audioPlayers[_currentAudioID];
    player->_alSource = alSource;
    player->_loop = loop;
    player->_volume = volume;
    audioCache->addCallbacks(std::bind(&AudioEngineImpl::_play2d,this,audioCache,_currentAudioID));
    
    _alSourceUsed[alSource] = true;
    return _currentAudioID++;
}

void AudioEngineImpl::_play2d(AudioCache *cache, int audioID)
{
    if(cache->_alBufferReady){
        auto playerIt = _audioPlayers.find(audioID);
        if (playerIt != _audioPlayers.end()) {
            if (playerIt->second.play2d(cache)) {
                AudioEngine::_audioIDInfoMap[audioID].state = AudioEngine::AudioState::PLAYING;            }
            else{
                _threadMutex.lock();
                _toRemoveAudioIDs.push_back(audioID);
                _threadMutex.unlock();
            }
        }
    }
    else {
        _threadMutex.lock();
        _toRemoveCaches.push_back(cache);
        _toRemoveAudioIDs.push_back(audioID);
        _threadMutex.unlock();
    }
}

void AudioEngineImpl::setVolume(int audioID,float volume)
{
    auto& player = _audioPlayers[audioID];
    player._volume = volume;
    
    if (player._ready) {
        alSourcef(_audioPlayers[audioID]._alSource, AL_GAIN, volume);
        
        auto error = alGetError();
        if (error != AL_NO_ERROR) {
            printf("%s: audio id = %d, error = %x\n", __PRETTY_FUNCTION__,audioID,error);
        }
    }
}

void AudioEngineImpl::setLoop(int audioID, bool loop)
{
    auto& player = _audioPlayers[audioID];
    
    if (player._ready) {
        if (player._streamingSource) {
            player.setLoop(loop);
        } else {
            if (loop) {
                alSourcei(player._alSource, AL_LOOPING, AL_TRUE);
            } else {
                alSourcei(player._alSource, AL_LOOPING, AL_FALSE);
            }
            
            auto error = alGetError();
            if (error != AL_NO_ERROR) {
                printf("%s: audio id = %d, error = %x\n", __PRETTY_FUNCTION__,audioID,error);
            }
        }
    }
    else {
        player._loop = loop;
    }
}

bool AudioEngineImpl::pause(int audioID)
{
    bool ret = true;
    alSourcePause(_audioPlayers[audioID]._alSource);
    
    auto error = alGetError();
    if (error != AL_NO_ERROR) {
        ret = false;
        printf("%s: audio id = %d, error = %x\n", __PRETTY_FUNCTION__,audioID,error);
    }
    
    return ret;
}

bool AudioEngineImpl::resume(int audioID)
{
    bool ret = true;
    alSourcePlay(_audioPlayers[audioID]._alSource);
    
    auto error = alGetError();
    if (error != AL_NO_ERROR) {
        ret = false;
        printf("%s: audio id = %d, error = %x\n", __PRETTY_FUNCTION__,audioID,error);
    }
    
    return ret;
}

bool AudioEngineImpl::stop(int audioID)
{
    bool ret = true;
    auto& player = _audioPlayers[audioID];
    if (player._ready) {
        alSourceStop(player._alSource);
        
        auto error = alGetError();
        if (error != AL_NO_ERROR) {
            ret = false;
            printf("%s: audio id = %d, error = %x\n", __PRETTY_FUNCTION__,audioID,error);
        }
    }
    
    alSourcei(player._alSource, AL_BUFFER, 0);
    
    _alSourceUsed[player._alSource] = false;
    _audioPlayers.erase(audioID);
    
    return ret;
}

void AudioEngineImpl::stopAll()
{
    for(int index = 0; index < MAX_AUDIOINSTANCES; ++index)
    {
        alSourceStop(_alSources[index]);
        alSourcei(_alSources[index], AL_BUFFER, 0);
        _alSourceUsed[_alSources[index]] = false;
    }
    
    _audioPlayers.clear();
}

float AudioEngineImpl::getDuration(int audioID)
{
    auto& player = _audioPlayers[audioID];
    if(player._ready){
        return player._audioCache->_duration;
    } else {
        return AudioEngine::TIME_UNKNOWN;
    }
}

float AudioEngineImpl::getCurrentTime(int audioID)
{
    float ret = 0.0f;
    auto& player = _audioPlayers[audioID];
    if(player._ready){
        if (player._streamingSource) {
            ret = player.getTime();
        } else {
            alGetSourcef(player._alSource, AL_SEC_OFFSET, &ret);
            
            auto error = alGetError();
            if (error != AL_NO_ERROR) {
                printf("%s, audio id:%d,error code:%x", __PRETTY_FUNCTION__,audioID,error);
            }
        }
    }
    
    return ret;
}

bool AudioEngineImpl::setCurrentTime(int audioID, float time)
{
    bool ret = false;
    auto& player = _audioPlayers[audioID];
    
    do {
        if (!player._ready) {
            break;
        }
        
        if (player._streamingSource) {
            ret = player.setTime(time);
            break;
        }
        else {
            if (player._audioCache->_bytesOfRead != player._audioCache->_dataSize &&
                (time * player._audioCache->_sampleRate * player._audioCache->_bytesPerFrame) > player._audioCache->_bytesOfRead) {
                printf("%s: audio id = %d\n", __PRETTY_FUNCTION__,audioID);
                break;
            }
            
            alSourcef(player._alSource, AL_SEC_OFFSET, time);
            
            auto error = alGetError();
            if (error != AL_NO_ERROR) {
                printf("%s: audio id = %d, error = %x\n", __PRETTY_FUNCTION__,audioID,error);
            }
            ret = true;
        }
    } while (0);
    
    return ret;
}

/*
void AudioEngineImpl::setFinishCallback(int audioID, const std::function<void (int, const std::string &)> &callback)
{
    _audioPlayers[audioID]._finishCallbak = callback;
}
 */

void AudioEngineImpl::removeAudioID(size_t audioID)
{
    auto playerIt = _audioPlayers.find(audioID);
    if (playerIt != _audioPlayers.end()) {
        _alSourceUsed[playerIt->second._alSource] = false;
        _audioPlayers.erase(audioID);
        AudioEngine::remove(audioID);
    }
}

void AudioEngineImpl::removeCache(AudioCache* cache)
{
    auto itEnd = _audioCaches.end();
    for (auto it = _audioCaches.begin(); it != itEnd; ++it) {
        if (&it->second == cache) {
            _audioCaches.erase(it);
            return;
        }
    }
}

void AudioEngineImpl::update()
{
    ALint sourceState;
    int audioID;
    
    if (_threadMutex.try_lock()) {
        size_t removeAudioCount = _toRemoveAudioIDs.size();
        for (size_t index = 0; index < removeAudioCount; ++index) {
            audioID = _toRemoveAudioIDs[index];
            auto playerIt = _audioPlayers.find(audioID);
            if (playerIt != _audioPlayers.end()) {
                _alSourceUsed[playerIt->second._alSource] = false;
                _audioPlayers.erase(audioID);
                AudioEngine::remove(audioID);
            }
        }
        size_t removeCacheCount = _toRemoveCaches.size();
        for (size_t index = 0; index < removeCacheCount; ++index) {
            auto itEnd = _audioCaches.end();
            for (auto it = _audioCaches.begin(); it != itEnd; ++it) {
                if (&it->second == _toRemoveCaches[index]) {
                    _audioCaches.erase(it);
                    break;
                }
            }
        }
        _threadMutex.unlock();
    }
    
    for (auto it = _audioPlayers.begin(); it != _audioPlayers.end(); ) {
        audioID = it->first;
        auto& player = it->second;
        alGetSourcei(player._alSource, AL_SOURCE_STATE, &sourceState);
        
        if (player._ready && sourceState == AL_STOPPED) {
            _alSourceUsed[player._alSource] = false;
            AudioEngine::remove(audioID);
            
            it = _audioPlayers.erase(it);
        }
        else{
            ++it;
        }
    }
    
}
 
void AudioEngineImpl::uncache(const std::string &filePath)
{
    _audioCaches.erase(filePath);
}

void AudioEngineImpl::uncacheAll()
{
    _audioCaches.clear();
}