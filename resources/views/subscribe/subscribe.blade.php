@extends('layout.master')

@section('title',  trans('cachet.subscriber.subscribe'). " | ". $siteTitle)

@section('description', trans('cachet.meta.description.subscribe', ['app' => $siteTitle]))

@section('content')
<div class="pull-right">
    <p><a class="btn btn-success btn-outline" href="{{ cachet_route('status-page') }}"><i class="ion ion-home"></i></a></p>
</div>

<div class="clearfix"></div>

@include('partials.errors')

<script src="https://www.google.com/recaptcha/api.js"></script>
<script>
   function onSubmit(token) {
     document.getElementById("subscribe-form").submit();
   }
 </script>
<div class="row">
    <div class="col-xs-12 col-lg-offset-2 col-lg-8">
        <div class="panel panel-default">
            <div class="panel-heading">{{ trans('cachet.subscriber.subscribe') }}</div>
            <div class="panel-body">
                <form action="{{ cachet_route('subscribe', [], 'post') }}" method="POST" id="subscribe-form" class="form">
                    <input type="hidden" name="_token" value="{{ csrf_token() }}">
                    <div class="form-group">
                        <input class="form-control" type="email" name="email" placeholder="email@example.com">
                    </div>
                    <button class="g-recaptcha btn btn-success" 
                        data-sitekey="{{ config('app.name') }}" 
                        data-callback='onSubmit' 
                        data-action='submit'>{{ trans('cachet.subscriber.button') }}</button>
                </form>
            </div>
        </div>
    </div>
</div>
@stop
