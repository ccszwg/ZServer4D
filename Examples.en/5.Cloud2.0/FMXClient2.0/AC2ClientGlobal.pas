﻿unit AC2ClientGlobal;

interface

uses
  FMX.Controls, FMX.Ani, FMX.Forms, FMX.Types, System.UITypes, FMX.Layouts,
  System.Types,
  IDGlobal,
  AC2KeepAwakeUnit,
  CommunicationFramework,
  PhysicsIO,
  CoreClasses, TextDataEngine,
  Cadencer,
  Classes, SysUtils, Geometry2DUnit, NotifyObjectBase,
  AC2ManagerServerMobileClient, CommonServiceDefine, AC2LogicMobileClient,
  FOGComputeClientIntf;

const
  GlobalScreenWidth = 960;
  GlobalScreenHeight = 540;

type
  TManagerQuery = class(TManagerQueryBase)
  public
    constructor Create;
    destructor Destroy; override;
    procedure Connect(Addr: string; Port: Word); override;
  end;

  TLogicClient = class(TLogicClientBase)
  public
    constructor Create(ALogicBackCallInterface: ILogicBackCallInterface);

    destructor Destroy; override;
    function Connect(Addr: string; const ARecvPort, ASendPort: Word): Boolean; override;
  end;

  TGlobalProgressThread = class(TThread)
  public
    procedure GlobalCadencerProgress(Sender: TObject; const deltaTime, newTime: Double);
    procedure SyncProgress;
    procedure Execute; override;
  end;

const
  CopyRightText: string = 'All copies are copyrighted. Zsserver4d advanced cloud server framework 2.0' + #13#10 + 'Version: 1.0.0 2018-1';
  AppName: string = 'Advanced cloud server framework 2.0';

var
  ManagerServerHost: string = '127.0.0.1';                {  The default server address. If it is the local loopback address of IPv6, write 0:0:0:0:0:0:1  }
  QueryClient: TManagerQuery = nil;                       {  Scheduling server (manager server)  }
  LogicClient: TLogicClient = nil;                        {  Business client (logic)  }
  FogComputeClient: TFogCompute_DoubleTunnelClient = nil; {  Fog compute client (fog compute)  }
  LastLoginUserID: string = '';                           {  Last login ID  }
  LastLoginUserAlias: string = '';                        {  Last logged in user alias  }
  UserConfig: TSectionTextData = nil;                     {  Last logged in remote user (can only be read and cannot be modified)  }
  GlobalKeepAwake: TKeepAwake = nil;                      {  Idle lock  }
  GlobalCadencer: TCadencer = nil;                        {  Cadencer engine  }
  GlobalProgressThread: TGlobalProgressThread = nil;      {  Idle processing threads are mainly used for global progress processing  }
  GlobalProgressThreadRuning: Boolean = True;             {  Execution state machine  }
  GlobalProgressPost: TNProgressPost = nil;               {  Event delivery engine  }

procedure KeepAwake;
procedure AllowSleeping;

procedure CreateAllForm(Sender: TNPostExecute);
procedure InitGlobalResource;
procedure FreeGlobalResource;

procedure ReStartAnimation(Owner: TControl);

procedure ResetFormSize(f: TForm);
procedure ResetMainLayout(l: TLayout; f: TForm);

implementation

uses
{$IF Defined(WIN32)}
{$ELSEIF Defined(WIN64)}
{$ELSEIF Defined(OSX)}
{$ELSEIF Defined(IOS)}
  iOSapi.Helpers,
{$ELSEIF Defined(ANDROID)}
  Androidapi.JNI.App,
  Androidapi.JNI.GraphicsContentViewText,
  Androidapi.Helpers,
  FMX.Helpers.Android,
  FMX.Platform.Android,
  Androidapi.JNI.Os, Androidapi.JNI.JavaTypes, Androidapi.JNIBridge,
{$ELSE}
{$IFEND}
  DoStatusIO, AC2LogicFrm, AC2LoginFrm, AC2ProgressFrm;

{$IF Defined(ANDROID)}


var
  FAwakeLock: JPowerManager_WakeLock = nil;

function GetPowerManager: JPowerManager;
begin
  Result := TJPowerManager.Wrap(TAndroidHelper.Context.getSystemService(TJContext.JavaClass.POWER_SERVICE));
  if Result = nil then
      raise Exception.Create('Could not get Power Service');
end;

procedure _KeepAwake;
var
  PowerManager: JPowerManager;
begin
  if FAwakeLock = nil then
    begin
      PowerManager := GetPowerManager;
      FAwakeLock := PowerManager.newWakeLock
        (TJPowerManager.JavaClass.SCREEN_BRIGHT_WAKE_LOCK
        or TJPowerManager.JavaClass.ACQUIRE_CAUSES_WAKEUP,
        StringToJString('mjClient'));
    end;

  if (FAwakeLock <> nil) and not FAwakeLock.isHeld then
      FAwakeLock.acquire;
end;

procedure _AllowSleeping;
begin
  if FAwakeLock <> nil then
    begin
      FAwakeLock.release;
      FAwakeLock := nil;
    end;
end;
{$ENDIF}


procedure KeepAwake;
begin
{$IF Defined(ANDROID)}
  _KeepAwake;
{$ENDIF}
end;

procedure AllowSleeping;
begin
{$IF Defined(ANDROID)}
  _AllowSleeping;
{$ENDIF}
end;

procedure TGlobalProgressThread.GlobalCadencerProgress(Sender: TObject; const deltaTime, newTime: Double);
begin
  GlobalProgressPost.Progress(deltaTime);

  QueryClient.Progress;
  LogicClient.Progress;
  FogComputeClient.Progress;
end;

procedure TGlobalProgressThread.SyncProgress;
begin
  if GlobalCadencer <> nil then
      GlobalCadencer.Progress;
end;

procedure TGlobalProgressThread.Execute;
begin
  FreeOnTerminate := True;

  while GlobalProgressThreadRuning do
    begin
      Synchronize(SyncProgress);
      Sleep(10);
    end;
end;

procedure CreateAllForm(Sender: TNPostExecute);
begin
  if AC2LogicForm = nil then
      AC2LogicForm := TAC2LogicForm.Create(Application);
  if AC2ProgressForm = nil then
      AC2ProgressForm := TAC2ProgressForm.Create(Application);
end;

procedure InitGlobalResource;
var
  stream: TStream;
begin

  GlobalKeepAwake := TKeepAwake.Create;
  // Once the application is connected with the targeted IDE
  // Setup events so the application can keep the device awake when active and allow sleeping when background
  GlobalKeepAwake.OnKeepAwake := KeepAwake;
  GlobalKeepAwake.OnAllowSleeping := AllowSleeping;
  // And force screen awake
  KeepAwake;

  GlobalCadencer := TCadencer.Create;

{$IF Defined(WIN32)}
{$ELSEIF Defined(WIN64)}
{$ELSEIF Defined(OSX)}
{$ELSEIF Defined(IOS)}
  TiOSHelper.SharedApplication.setIdleTimerDisabled(True);
{$ELSEIF Defined(ANDROID)}
  CallInUIThread(
    procedure
    begin
      MainActivity.getWindow.clearFlags(TJWindowManager_LayoutParams.JavaClass.FLAG_KEEP_SCREEN_ON);
    end);
{$ELSE}
{$IFEND}
  GlobalProgressThreadRuning := True;
  GlobalProgressThread := TGlobalProgressThread.Create(True);
  GlobalCadencer.OnProgress := GlobalProgressThread.GlobalCadencerProgress;
  GlobalProgressThread.Suspended := False;

  GlobalProgressPost := TNProgressPost.Create;

  QueryClient := TManagerQuery.Create;

  if AC2LogicForm = nil then
      AC2LogicForm := TAC2LogicForm.Create(Application);

  LogicClient := TLogicClient.Create(AC2LogicForm);

  FogComputeClient := TFogCompute_DoubleTunnelClient.Create(TPhysicsClient);

  GlobalProgressPost.PostExecuteC(1, CreateAllForm);
end;

procedure FreeGlobalResource;
begin
  GlobalProgressThreadRuning := False;
  DisposeObject(QueryClient);
  DisposeObject(LogicClient);
  DisposeObject(FogComputeClient);
  DisposeObject(GlobalProgressPost);
  DisposeObject(GlobalCadencer);

  GlobalCadencer := nil;

  AC2LogicForm := nil;
  AC2LoginForm := nil;
end;

procedure ReStartAnimation(Owner: TControl);
var
  i: Integer;
begin
  for i := 0 to Owner.ChildrenCount - 1 do
    if (Owner.Children[i] is TAnimation) and (TAnimation(Owner.Children[i]).Enabled) and (not TAnimation(Owner.Children[i]).Loop) then
        TAnimation(Owner.Children[i]).Start
    else if (Owner.Children[i] is TControl) and (TControl(Owner.Children[i]).Visible) then
        ReStartAnimation(TControl(Owner.Children[i]));
end;

procedure ResetFormSize(f: TForm);
begin
  if IsMobile then
    begin
      f.BorderStyle := TFmxFormBorderStyle.None;
      f.WindowState := TWindowState.wsMaximized;
    end
  else
    begin
      f.BeginUpdate;
      if (f <> AC2LoginForm) and (AC2LoginForm <> nil) then
        begin
          f.Bounds := AC2LoginForm.Bounds;
        end
      else if (f.ClientWidth <> GlobalScreenWidth) or (f.ClientHeight <> GlobalScreenHeight) then
        begin
          f.ClientWidth := GlobalScreenWidth;
          f.ClientHeight := GlobalScreenHeight;
        end;
      f.EndUpdate;
    end;
end;

procedure FitScale(const sour, dest: TRect2D; var outOffset: TVec2; var outScale: TGeoFloat); overload;
var
  r: TRect2D;
begin
  // compute scale
  r := RectFit(sour, dest);
  outScale := RectWidth(r) / RectWidth(sour);
  outOffset := r[0];
end;

procedure FitScale(const sour: TRect2D; const destWidth, destHeight: TGeoFloat; var outOffset: TVec2; var outScale: TGeoFloat); overload;
begin
  FitScale(sour, MakeRectV2(0, 0, destWidth, destHeight), outOffset, outScale);
end;

procedure ResetMainLayout(l: TLayout; f: TForm);
var
  pt: TVec2;
  sa: TGeoFloat;
begin
  // compute scale
  FitScale(MakeRectV2(0, 0, GlobalScreenWidth, GlobalScreenHeight), f.ClientWidth, f.ClientHeight, pt, sa);
  l.BeginUpdate;
  l.Scale.Point := Pointf(sa, sa);
  l.Position.Point := MakePointf(pt);
  l.EndUpdate;
end;

constructor TManagerQuery.Create;
begin
  inherited Create(TPhysicsClient.Create);
end;

destructor TManagerQuery.Destroy;
begin
  inherited Destroy;
end;

procedure TManagerQuery.Connect(Addr: string; Port: Word);
begin
  TPhysicsClient(Client).Connect(Addr, Port);
end;

constructor TLogicClient.Create(ALogicBackCallInterface: ILogicBackCallInterface);
begin
  inherited Create(ALogicBackCallInterface, TPhysicsClient.Create, TPhysicsClient.Create);
end;

destructor TLogicClient.Destroy;
begin
  inherited Destroy;
end;

function TLogicClient.Connect(Addr: string; const ARecvPort, ASendPort: Word): Boolean;
var
  t: Cardinal;
begin
  Result := False;
  Disconnect;
  RegisterCommand;

  TPhysicsClient(NetSendTunnelIntf).Connect(Addr, ASendPort);
  if not NetSendTunnelIntf.Connected then
    begin
      DoStatus('connect %s failed!', [Addr]);
      exit;
    end;
  TPhysicsClient(NetRecvTunnelIntf).Connect(Addr, ARecvPort);
  if not NetRecvTunnelIntf.Connected then
    begin
      DoStatus('connect %s failed!', [Addr]);
      exit;
    end;

  t := GetTimeTickCount + 5000;
  while not RemoteInited do
    begin
      if GetTimeTickCount > t then
          break;
      if not Connected then
          break;
      Progress;
    end;

  if Connected then
    begin
      DoStatus('connect logic service "%s" ok!', [Addr]);
      Result := True;
      LastConnectState := True;
    end;
end;

procedure QPProgressBackground;
begin
  Application.ProcessMessages;
end;

initialization

UserConfig := TSectionTextData.Create;
GlobalProgressThreadRuning := True;

ProgressBackgroundProc := QPProgressBackground;

finalization

DisposeObject(UserConfig);
GlobalProgressThreadRuning := False;
ProgressBackgroundProc := nil;

end.
